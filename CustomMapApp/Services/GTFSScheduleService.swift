import Foundation
import CoreLocation

// MARK: - GTFS Schedule Models

struct GTFSTrip: Codable {
    let tripId: String
    let routeId: String
    let serviceId: String
    let directionId: Int       // 0 or 1
    var routeShortName: String // from routes.txt lookup
    var shapeId: String        // maps to shapes.txt for route geometry
}

struct GTFSStopTime: Comparable, Codable {
    let tripId: String
    let stopId: String
    let arrivalTime: String    // HH:MM:SS (can be > 24:00 for next-day)
    let departureTime: String
    let stopSequence: Int

    /// Convert HH:MM:SS to seconds since midnight
    var arrivalSeconds: Int {
        timeToSeconds(arrivalTime)
    }

    var departureSeconds: Int {
        timeToSeconds(departureTime)
    }

    static func < (lhs: GTFSStopTime, rhs: GTFSStopTime) -> Bool {
        lhs.stopSequence < rhs.stopSequence
    }

    private func timeToSeconds(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

struct GTFSServiceCalendar: Codable {
    let serviceId: String
    let monday: Bool
    let tuesday: Bool
    let wednesday: Bool
    let thursday: Bool
    let friday: Bool
    let saturday: Bool
    let sunday: Bool
    let startDate: String  // YYYYMMDD
    let endDate: String

    func runsOn(weekday: Int) -> Bool {
        // Calendar weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
        switch weekday {
        case 1: return sunday
        case 2: return monday
        case 3: return tuesday
        case 4: return wednesday
        case 5: return thursday
        case 6: return friday
        case 7: return saturday
        default: return false
        }
    }
}

// MARK: - GTFS Schedule Service

/// Parses and caches GTFS schedule data from the downloaded ZIP.
/// Used by TransitRoutePlanner to find connections.
actor GTFSScheduleService {
    static let shared = GTFSScheduleService()

    private var trips: [String: GTFSTrip] = [:]           // tripId → trip
    private var stopTimes: [String: [GTFSStopTime]] = [:] // stopId → sorted by departureSeconds
    private var tripStopTimes: [String: [GTFSStopTime]] = [:] // tripId → sorted by stopSequence
    private var calendars: [String: GTFSServiceCalendar] = [:] // serviceId → calendar
    private var isLoaded = false

    // Cached active service IDs for today (avoids repeated calendar lookups)
    private var cachedActiveServiceIds: Set<String> = []
    private var cachedWeekday: Int = -1

    /// Load schedule data from the cached GTFS ZIP
    func loadIfNeeded() async {
        guard !isLoaded else { return }

        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        // Try to load from pre-parsed cache first
        if loadParsedCache(from: cacheURL) {
            isLoaded = true
            await APILogger.shared.log(service: "TFI", endpoint: "GTFS schedule (cached)", status: .cached, durationMs: 0, detail: "\(trips.count) trips, \(stopTimes.count) stops")
            return
        }

        // Download and parse fresh
        let loader = GTFSStopLoader()
        // The loader already downloads GTFS_All.zip — we need the raw ZIP data
        // For now, download it ourselves
        let urls = [
            "https://www.transportforireland.ie/transitData/Data/GTFS_All.zip",
            "https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            let start = Date()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 120
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ms = Int(Date().timeIntervalSince(start) * 1000)

                guard httpStatus == 200 else { continue }

                await APILogger.shared.trackBytes(data.count)
                GTFSStopLoader.cacheRawZip(data)  // Cache for lazy shapes.txt extraction
                await parseScheduleFromZip(data: data)
                await APILogger.shared.log(service: "TFI", endpoint: "GTFS schedule parsed", status: .success, durationMs: ms, detail: "\(trips.count) trips, \(stopTimes.count) stops")
                isLoaded = true

                // Cache parsed data
                saveParsedCache(to: cacheURL)
                return
            } catch {
                continue
            }
        }
    }

    // MARK: - Query Methods

    /// Find trips departing from a stop within a time window.
    /// Uses binary search on pre-sorted stop times for O(log n + results) instead of O(n).
    func departuresFromStop(stopId: String, afterSeconds: Int, withinSeconds: Int = 1200) -> [(GTFSStopTime, GTFSTrip)] {
        guard let times = stopTimes[stopId], !times.isEmpty else { return [] }
        let activeServices = activeServiceIds()
        let upperBound = afterSeconds + withinSeconds

        // Binary search for the first departure >= afterSeconds
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid].departureSeconds < afterSeconds { lo = mid + 1 } else { hi = mid }
        }

        var results: [(GTFSStopTime, GTFSTrip)] = []
        for i in lo..<times.count {
            let st = times[i]
            guard st.departureSeconds <= upperBound else { break }
            guard let trip = trips[st.tripId],
                  activeServices.contains(trip.serviceId) else { continue }
            results.append((st, trip))
        }
        return results
    }

    /// Get all stops for a trip (in order)
    func stopsForTrip(tripId: String) -> [GTFSStopTime] {
        tripStopTimes[tripId] ?? []
    }

    /// Check if a trip passes through a specific stop (after a given sequence)
    func tripReachesStop(tripId: String, stopId: String, afterSequence: Int) -> GTFSStopTime? {
        guard let times = tripStopTimes[tripId] else { return nil }
        return times.first { $0.stopId == stopId && $0.stopSequence > afterSequence }
    }

    /// Find nearby stop IDs from our transit stop data
    func findNearbyStopIds(coordinate: CLLocationCoordinate2D, radiusMeters: Double, allStops: [TransitStop]) -> [String] {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return allStops
            .filter { stop in
                let stopLoc = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
                return stopLoc.distance(from: location) <= radiusMeters
            }
            .map { $0.id }
    }

    var tripCount: Int { trips.count }
    var stopCount: Int { stopTimes.count }

    /// Get shape ID for a trip (used for lazy shapes.txt loading)
    func shapeId(forTripId tripId: String) -> String? {
        guard let trip = trips[tripId], !trip.shapeId.isEmpty else { return nil }
        return trip.shapeId
    }

    /// Find any trip for a given route ID (for looking up shape when we only have route info)
    func anyTripForRoute(routeId: String) -> GTFSTrip? {
        trips.values.first { $0.routeId == routeId && !$0.shapeId.isEmpty }
    }

    /// Compute and cache active service IDs for today's weekday.
    /// Invalidates automatically when the weekday changes.
    private func activeServiceIds() -> Set<String> {
        let today = Calendar.current.component(.weekday, from: Date())
        if today == cachedWeekday { return cachedActiveServiceIds }
        cachedActiveServiceIds = Set(calendars.filter { $0.value.runsOn(weekday: today) }.map { $0.key })
        cachedWeekday = today
        return cachedActiveServiceIds
    }

    // MARK: - Parsing

    private func parseScheduleFromZip(data: Data) async {
        let loader = GTFSStopLoader()

        // Parse trips.txt
        if let tripsCSV = await loader.extractFile(from: data, named: "trips.txt") {
            parseTrips(csv: tripsCSV)
        }

        // Parse stop_times.txt
        if let stopTimesCSV = await loader.extractFile(from: data, named: "stop_times.txt") {
            parseStopTimes(csv: stopTimesCSV)
        }

        // Parse calendar.txt
        if let calendarCSV = await loader.extractFile(from: data, named: "calendar.txt") {
            parseCalendar(csv: calendarCSV)
        }
    }

    private func parseTrips(csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return }
        let headers = parseCSVRow(header)

        guard let tripIdx = headers.firstIndex(of: "trip_id"),
              let routeIdx = headers.firstIndex(of: "route_id"),
              let serviceIdx = headers.firstIndex(of: "service_id") else { return }
        let dirIdx = headers.firstIndex(of: "direction_id")
        let shapeIdx = headers.firstIndex(of: "shape_id")

        let routeLookup = GTFSStopLoader.routeNameLookup

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(tripIdx, routeIdx, serviceIdx) else { continue }
            let tripId = fields[tripIdx]
            let routeId = fields[routeIdx]
            guard !tripId.isEmpty else { continue }

            trips[tripId] = GTFSTrip(
                tripId: tripId,
                routeId: routeId,
                serviceId: fields[serviceIdx],
                directionId: dirIdx.flatMap { fields.count > $0 ? Int(fields[$0]) : nil } ?? 0,
                routeShortName: routeLookup[routeId] ?? routeId,
                shapeId: shapeIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            )
        }
    }

    private func parseStopTimes(csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return }
        let headers = parseCSVRow(header)

        guard let tripIdx = headers.firstIndex(of: "trip_id"),
              let stopIdx = headers.firstIndex(of: "stop_id"),
              let arrIdx = headers.firstIndex(of: "arrival_time"),
              let depIdx = headers.firstIndex(of: "departure_time"),
              let seqIdx = headers.firstIndex(of: "stop_sequence") else { return }

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(tripIdx, stopIdx, arrIdx, depIdx, seqIdx) else { continue }
            let tripId = fields[tripIdx]
            let stopId = fields[stopIdx]
            guard !tripId.isEmpty, !stopId.isEmpty else { continue }

            let st = GTFSStopTime(
                tripId: tripId,
                stopId: stopId,
                arrivalTime: fields[arrIdx],
                departureTime: fields[depIdx],
                stopSequence: Int(fields[seqIdx]) ?? 0
            )
            stopTimes[stopId, default: []].append(st)
            tripStopTimes[tripId, default: []].append(st)
        }

        // Sort stopTimes by departureSeconds for binary search in departuresFromStop
        for key in stopTimes.keys {
            stopTimes[key]?.sort { $0.departureSeconds < $1.departureSeconds }
        }
        // Sort tripStopTimes by stopSequence for ordered traversal
        for key in tripStopTimes.keys {
            tripStopTimes[key]?.sort { $0.stopSequence < $1.stopSequence }
        }
    }

    private func parseCalendar(csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return }
        let headers = parseCSVRow(header)

        guard let sidIdx = headers.firstIndex(of: "service_id"),
              let monIdx = headers.firstIndex(of: "monday"),
              let tueIdx = headers.firstIndex(of: "tuesday"),
              let wedIdx = headers.firstIndex(of: "wednesday"),
              let thuIdx = headers.firstIndex(of: "thursday"),
              let friIdx = headers.firstIndex(of: "friday"),
              let satIdx = headers.firstIndex(of: "saturday"),
              let sunIdx = headers.firstIndex(of: "sunday") else { return }

        let startIdx = headers.firstIndex(of: "start_date")
        let endIdx = headers.firstIndex(of: "end_date")

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(sidIdx, sunIdx) else { continue }
            let serviceId = fields[sidIdx]
            guard !serviceId.isEmpty else { continue }

            calendars[serviceId] = GTFSServiceCalendar(
                serviceId: serviceId,
                monday: fields[monIdx] == "1",
                tuesday: fields[tueIdx] == "1",
                wednesday: fields[wedIdx] == "1",
                thursday: fields[thuIdx] == "1",
                friday: fields[friIdx] == "1",
                saturday: fields[satIdx] == "1",
                sunday: fields[sunIdx] == "1",
                startDate: startIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? "",
                endDate: endIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            )
        }
    }

    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in row {
            if char == "\"" { inQuotes.toggle() }
            else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else { current.append(char) }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: - Binary Parsed Cache

    private static let cacheMaxAge: TimeInterval = 7 * 24 * 3600 // 7 days

    /// Serializable wrapper for the full parsed schedule
    private struct ScheduleCache: Codable {
        let trips: [String: GTFSTrip]
        let stopTimes: [String: [GTFSStopTime]]
        let tripStopTimes: [String: [GTFSStopTime]]
        let calendars: [String: GTFSServiceCalendar]
    }

    private func saveParsedCache(to dir: URL) {
        let cache = ScheduleCache(
            trips: trips,
            stopTimes: stopTimes,
            tripStopTimes: tripStopTimes,
            calendars: calendars
        )
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: dir.appendingPathComponent("gtfs_schedule_cache.json"))
            await APILogger.shared.log(
                service: "TFI", endpoint: "GTFS schedule cache saved",
                status: .success, durationMs: 0,
                detail: "\(data.count / 1024)KB — \(trips.count) trips, \(stopTimes.count) stops"
            )
        } catch {
            // Cache save failure is non-fatal — next launch will re-parse
        }
    }

    private func loadParsedCache(from dir: URL) -> Bool {
        let cacheFile = dir.appendingPathComponent("gtfs_schedule_cache.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < Self.cacheMaxAge else {
            return false
        }

        do {
            let start = Date()
            let data = try Data(contentsOf: cacheFile)
            let cache = try JSONDecoder().decode(ScheduleCache.self, from: data)
            self.trips = cache.trips
            self.stopTimes = cache.stopTimes
            self.tripStopTimes = cache.tripStopTimes
            self.calendars = cache.calendars
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            // Log will be called by the caller
            return !trips.isEmpty
        } catch {
            return false
        }
    }
}

// MARK: - Expose ZIP extraction from GTFSStopLoader

extension GTFSStopLoader {
    /// Extract a named file from ZIP data (exposed for GTFSScheduleService)
    func extractFile(from data: Data, named fileName: String) -> String? {
        extractFileFromZip(data: data, fileName: fileName)
    }
}
