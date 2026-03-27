import Foundation
import CoreLocation
import SQLite3

// MARK: - GTFS Schedule Models (lightweight — used for query results only)

struct GTFSTrip: Codable {
    let tripId: String
    let routeId: String
    let serviceId: String
    let directionId: Int
    var routeShortName: String
    var shapeId: String
    var routeType: Int = 3  // GTFS route_type: 0=tram/luas, 2=rail/dart, 3=bus
}

struct GTFSStopTime: Comparable, Codable {
    let tripId: String
    let stopId: String
    let arrivalTime: String
    let departureTime: String
    let stopSequence: Int

    var arrivalSeconds: Int { timeToSeconds(arrivalTime) }
    var departureSeconds: Int { timeToSeconds(departureTime) }

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
    let startDate: String
    let endDate: String

    func runsOn(weekday: Int) -> Bool {
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

// MARK: - GTFS Schedule Service (SQLite-backed)

/// Queries GTFS schedule data from a SQLite database (~50 MB on disk)
/// instead of loading ~875 MB into RAM. Queries only load needed rows.
actor GTFSScheduleService {
    static let shared = GTFSScheduleService()

    private let db = GTFSDatabase()
    private var isLoaded = false

    /// Weekday column names for SQL calendar queries
    private static let weekdayColumns = [
        "", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"
    ]

    // MARK: - Loading

    func loadIfNeeded() async {
        guard !isLoaded else { return }

        // Check if SQLite database is fresh AND has data
        if GTFSDatabase.isFresh {
            if db.open() {
                let trips = db.count(table: "trips")
                if trips > 0 {
                    isLoaded = true
                    await APILogger.shared.log(service: "TFI", endpoint: "GTFS schedule (SQLite)", status: .cached, durationMs: 0, detail: "\(trips) trips")
                    return
                }
                // Database exists but has 0 trips — likely bad parse, re-download
                db.close()
                try? FileManager.default.removeItem(atPath: GTFSDatabase.defaultPath)
                await APILogger.shared.log(service: "TFI", endpoint: "GTFS schedule (SQLite)", status: .failure, durationMs: 0, detail: "Cached DB has 0 trips — re-downloading")
            }
        }

        // Try cached ZIP first (GTFSStopLoader already downloaded it — avoids a second 65 MB download)
        if GTFSStopLoader.hasCachedZip,
           let cachedData = try? Data(contentsOf: GTFSStopLoader.cachedZipURL) {
            let start = Date()
            try? FileManager.default.removeItem(atPath: GTFSDatabase.defaultPath)
            if db.open() {
                db.createTables()
                db.execute("PRAGMA synchronous = OFF")  // Safe: fresh DB, crash = retry
                await parseScheduleFromZip(data: cachedData)
                db.createIndexes()
                db.execute("PRAGMA optimize")
                db.execute("PRAGMA synchronous = NORMAL")
                let trips = db.count(table: "trips")
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if trips > 0 {
                    let stopTimes = db.count(table: "stop_times")
                    let routes = db.count(table: "routes")
                    let shapes = db.count(table: "shapes")
                    await APILogger.shared.log(
                        service: "TFI", endpoint: "GTFS → SQLite (cached ZIP)",
                        status: .success, durationMs: ms,
                        detail: "\(trips) trips, \(stopTimes) stop_times, \(routes) routes, \(shapes) shapes. Parse: \(ms)ms"
                    )
                    isLoaded = true
                    return
                }
                db.close()
            }
        }

        // No cached ZIP — download fresh
        let urls = [
            "https://www.transportforireland.ie/transitData/Data/GTFS_All.zip",
            "https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            let start = Date()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 300  // TFI server can be very slow
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ms = Int(Date().timeIntervalSince(start) * 1000)

                guard httpStatus == 200 else { continue }

                await APILogger.shared.trackBytes(data.count)
                GTFSStopLoader.cacheRawZip(data)

                // Delete old database and create fresh
                try? FileManager.default.removeItem(atPath: GTFSDatabase.defaultPath)
                guard db.open() else { continue }
                db.createTables()
                db.execute("PRAGMA synchronous = OFF")  // Safe: fresh DB, crash = retry

                // Parse CSV directly into SQLite
                let parseStart = Date()
                await parseScheduleFromZip(data: data)
                db.createIndexes()
                db.execute("PRAGMA optimize")
                db.execute("PRAGMA synchronous = NORMAL")

                let totalMs = Int(Date().timeIntervalSince(start) * 1000)
                let parseMs = Int(Date().timeIntervalSince(parseStart) * 1000)
                let trips = db.count(table: "trips")
                let stopTimes = db.count(table: "stop_times")
                let routes = db.count(table: "routes")
                let shapes = db.count(table: "shapes")
                await APILogger.shared.log(
                    service: "TFI", endpoint: "GTFS → SQLite",
                    status: trips > 0 ? .success : .failure, durationMs: totalMs,
                    detail: "\(trips) trips, \(stopTimes) stop_times, \(routes) routes, \(shapes) shapes. Download: \(ms)ms, Parse: \(parseMs)ms"
                )
                if trips > 0 {
                    isLoaded = true
                    return
                }
                // Parse failed — try next URL
                continue
            } catch {
                continue
            }
        }
    }

    // MARK: - Query Methods

    /// Find trips departing from a stop within a time window.
    func departuresFromStop(stopId: String, afterSeconds: Int, withinSeconds: Int = 1200) -> [(GTFSStopTime, GTFSTrip)] {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let weekdayCol = Self.weekdayColumns[weekday]
        let upperBound = afterSeconds + withinSeconds

        let sql = """
            SELECT st.trip_id, st.stop_id, st.departure_seconds, st.stop_sequence, st.departure_time,
                   t.route_id, t.service_id, t.direction_id, t.route_short_name, t.shape_id,
                   COALESCE(r.route_type, 3)
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN calendars c ON t.service_id = c.service_id
            LEFT JOIN routes r ON t.route_id = r.route_id
            WHERE st.stop_id = ? AND st.departure_seconds >= ? AND st.departure_seconds <= ?
            AND c.\(weekdayCol) = 1
            ORDER BY st.departure_seconds
            LIMIT 50
        """

        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (stopId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(afterSeconds))
        sqlite3_bind_int(stmt, 3, Int32(upperBound))

        var results: [(GTFSStopTime, GTFSTrip)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tripId = db.columnText(stmt, index: 0) ?? ""
            let st = GTFSStopTime(
                tripId: tripId,
                stopId: db.columnText(stmt, index: 1) ?? "",
                arrivalTime: db.columnText(stmt, index: 4) ?? "",
                departureTime: db.columnText(stmt, index: 4) ?? "",
                stopSequence: db.columnInt(stmt, index: 3)
            )
            let trip = GTFSTrip(
                tripId: tripId,
                routeId: db.columnText(stmt, index: 5) ?? "",
                serviceId: db.columnText(stmt, index: 6) ?? "",
                directionId: db.columnInt(stmt, index: 7),
                routeShortName: db.columnText(stmt, index: 8) ?? "",
                shapeId: db.columnText(stmt, index: 9) ?? "",
                routeType: db.columnInt(stmt, index: 10)
            )
            results.append((st, trip))
        }
        return results
    }

    /// Get all stops for a trip (in order)
    func stopsForTrip(tripId: String) -> [GTFSStopTime] {
        let sql = "SELECT trip_id, stop_id, departure_seconds, departure_time, stop_sequence FROM stop_times WHERE trip_id = ? ORDER BY stop_sequence"
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)

        var results: [GTFSStopTime] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(GTFSStopTime(
                tripId: db.columnText(stmt, index: 0) ?? "",
                stopId: db.columnText(stmt, index: 1) ?? "",
                arrivalTime: db.columnText(stmt, index: 3) ?? "",
                departureTime: db.columnText(stmt, index: 3) ?? "",
                stopSequence: db.columnInt(stmt, index: 4)
            ))
        }
        return results
    }

    /// Check if a trip passes through a specific stop (after a given sequence)
    func tripReachesStop(tripId: String, stopId: String, afterSequence: Int) -> GTFSStopTime? {
        let sql = "SELECT trip_id, stop_id, departure_seconds, departure_time, stop_sequence FROM stop_times WHERE trip_id = ? AND stop_id = ? AND stop_sequence > ? ORDER BY stop_sequence LIMIT 1"
        guard let stmt = db.prepare(sql) else { return nil }
        defer { db.finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (stopId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(afterSequence))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return GTFSStopTime(
            tripId: db.columnText(stmt, index: 0) ?? "",
            stopId: db.columnText(stmt, index: 1) ?? "",
            arrivalTime: db.columnText(stmt, index: 3) ?? "",
            departureTime: db.columnText(stmt, index: 3) ?? "",
            stopSequence: db.columnInt(stmt, index: 4)
        )
    }

    /// Find nearby stop IDs from transit stop data (unchanged — uses in-memory stop list)
    func findNearbyStopIds(coordinate: CLLocationCoordinate2D, radiusMeters: Double, allStops: [TransitStop]) -> [String] {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return allStops
            .filter { stop in
                let stopLoc = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
                return stopLoc.distance(from: location) <= radiusMeters
            }
            .map { $0.id }
    }

    /// Routes that serve a given stop (for bus timetable view)
    func routesForStop(stopId: String) -> [(routeId: String, routeName: String)] {
        let sql = """
            SELECT DISTINCT t.route_id, t.route_short_name
            FROM stop_times st JOIN trips t ON st.trip_id = t.trip_id
            WHERE st.stop_id = ?
            ORDER BY t.route_short_name
        """
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (stopId as NSString).utf8String, -1, nil)

        var results: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let routeId = db.columnText(stmt, index: 0) ?? ""
            let routeName = db.columnText(stmt, index: 1) ?? routeId
            results.append((routeId, routeName))
        }
        return results
    }

    var tripCount: Int { db.count(table: "trips") }
    var stopCount: Int {
        guard let stmt = db.prepare("SELECT COUNT(DISTINCT stop_id) FROM stop_times") else { return 0 }
        defer { db.finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return db.columnInt(stmt, index: 0)
    }

    /// Get shape ID for a trip
    func shapeId(forTripId tripId: String) -> String? {
        let sql = "SELECT shape_id FROM trips WHERE trip_id = ? AND shape_id != '' LIMIT 1"
        guard let stmt = db.prepare(sql) else { return nil }
        defer { db.finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return db.columnText(stmt, index: 0)
    }

    /// Find any trip for a given route ID (for shape lookup)
    func anyTripForRoute(routeId: String) -> GTFSTrip? {
        let sql = """
            SELECT t.trip_id, t.route_id, t.service_id, t.direction_id, t.route_short_name, t.shape_id,
                   COALESCE(r.route_type, 3)
            FROM trips t
            LEFT JOIN routes r ON t.route_id = r.route_id
            WHERE t.route_id = ? AND t.shape_id != '' LIMIT 1
        """
        guard let stmt = db.prepare(sql) else { return nil }
        defer { db.finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (routeId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return GTFSTrip(
            tripId: db.columnText(stmt, index: 0) ?? "",
            routeId: db.columnText(stmt, index: 1) ?? "",
            serviceId: db.columnText(stmt, index: 2) ?? "",
            directionId: db.columnInt(stmt, index: 3),
            routeShortName: db.columnText(stmt, index: 4) ?? "",
            shapeId: db.columnText(stmt, index: 5) ?? "",
            routeType: db.columnInt(stmt, index: 6)
        )
    }

    /// Query shape coordinates from SQLite (indexed, ~10ms)
    func shapeCoordinates(for shapeId: String) -> [CLLocationCoordinate2D] {
        let sql = "SELECT lat, lon FROM shapes WHERE shape_id = ? ORDER BY sequence"
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (shapeId as NSString).utf8String, -1, nil)

        var coords: [CLLocationCoordinate2D] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lat = sqlite3_column_double(stmt, 0)
            let lon = sqlite3_column_double(stmt, 1)
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return coords
    }

    /// Get all unique stop IDs served by a route (for filtering map annotations)
    func stopIdsForRoute(routeId: String) -> Set<String> {
        let sql = """
            SELECT DISTINCT st.stop_id FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            WHERE t.route_id = ?
        """
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (routeId as NSString).utf8String, -1, nil)

        var ids = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = db.columnText(stmt, index: 0) { ids.insert(id) }
        }
        return ids
    }

    /// Authoritative stop classification using GTFS route_type and route_short_name.
    /// Returns stop_id → TransitStopType string ("luas", "dart", or "rail").
    /// DART is identified by route_short_name = 'DART' (the only reliable marker
    /// in the TFI GTFS feed — all Irish Rail services share route_type=2).
    /// Stops NOT in the result should be classified as bus.
    func classifyTramAndRailStops() -> [String: String] {
        // Step 1: Find all stops served by DART specifically
        let dartSQL = """
            SELECT DISTINCT st.stop_id
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 2 AND UPPER(r.route_short_name) = 'DART'
        """
        var dartStopIds = Set<String>()
        if let stmt = db.prepare(dartSQL) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let stopId = db.columnText(stmt, index: 0) {
                    dartStopIds.insert(stopId)
                }
            }
            db.finalize(stmt)
        }

        // Step 2: Find all stops served by tram (0) or rail (2)
        let sql = """
            SELECT st.stop_id, MIN(r.route_type)
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type IN (0, 2)
            GROUP BY st.stop_id
        """
        guard let stmt = db.prepare(sql) else { return [:] }
        defer { db.finalize(stmt) }

        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stopId = db.columnText(stmt, index: 0) {
                let routeType = db.columnInt(stmt, index: 1)
                if routeType == 0 {
                    result[stopId] = "luas"
                } else if dartStopIds.contains(stopId) {
                    result[stopId] = "dart"
                } else {
                    result[stopId] = "rail"
                }
            }
        }
        return result
    }

    /// Find one representative shape per route+direction for a given GTFS route_type.
    /// GROUP BY route_id, direction_id ensures every route/direction gets one shape.
    /// route_type: 0=tram, 1=subway, 2=rail, 3=bus
    func shapeCoordinatesForRouteType(_ routeType: Int) -> [[CLLocationCoordinate2D]] {
        let sql = """
            SELECT MIN(t.shape_id)
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = ? AND t.shape_id != ''
            GROUP BY r.route_id, t.direction_id
        """
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(routeType))

        var shapeIds: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = db.columnText(stmt, index: 0) { shapeIds.append(id) }
        }

        return shapeIds.compactMap { id in
            let coords = shapeCoordinates(for: id)
            return coords.count >= 2 ? coords : nil
        }
    }

    /// Shape coordinates for DART routes only (route_short_name = 'DART').
    func shapeCoordinatesForDART() -> [[CLLocationCoordinate2D]] {
        let sql = """
            SELECT MIN(t.shape_id)
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 2 AND UPPER(r.route_short_name) = 'DART' AND t.shape_id != ''
            GROUP BY r.route_id, t.direction_id
        """
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }

        var shapeIds: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = db.columnText(stmt, index: 0) { shapeIds.append(id) }
        }

        return shapeIds.compactMap { id in
            let coords = shapeCoordinates(for: id)
            return coords.count >= 2 ? coords : nil
        }
    }

    /// Shape coordinates for non-DART rail (Commuter, InterCity, etc.)
    func shapeCoordinatesForNonDartRail() -> [[CLLocationCoordinate2D]] {
        let sql = """
            SELECT MIN(t.shape_id)
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 2 AND UPPER(r.route_short_name) != 'DART' AND t.shape_id != ''
            GROUP BY r.route_id, t.direction_id
        """
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }

        var shapeIds: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = db.columnText(stmt, index: 0) { shapeIds.append(id) }
        }

        return shapeIds.compactMap { id in
            let coords = shapeCoordinates(for: id)
            return coords.count >= 2 ? coords : nil
        }
    }

    /// Log what route types and names exist in the database (for debugging)
    func logRouteTypes() async {
        let sql = "SELECT route_type, route_short_name, route_long_name, COUNT(*) FROM routes GROUP BY route_type ORDER BY route_type"
        guard let stmt = db.prepare(sql) else { return }
        defer { db.finalize(stmt) }

        var detail = ""
        while sqlite3_step(stmt) == SQLITE_ROW {
            let type = db.columnInt(stmt, index: 0)
            let name = db.columnText(stmt, index: 1) ?? "?"
            let longName = db.columnText(stmt, index: 2) ?? ""
            let count = db.columnInt(stmt, index: 3)
            let typeName = ["Tram", "Subway", "Rail", "Bus"][min(type, 3)]
            detail += "\(typeName)(\(type)): \(count) routes (e.g. \(name) \(longName)). "
        }
        await APILogger.shared.log(service: "GTFS", endpoint: "route_types", status: .success, durationMs: 0, detail: detail)
    }

    /// Database age description for staleness display
    var dataAge: String? { GTFSDatabase.ageDescription }

    // MARK: - Parsing (CSV → SQLite)

    private func parseScheduleFromZip(data: Data) async {
        let loader = GTFSStopLoader()

        if let tripsCSV = await loader.extractFile(from: data, named: "trips.txt") {
            parseTrips(csv: tripsCSV)
        }
        if let stopTimesCSV = await loader.extractFile(from: data, named: "stop_times.txt") {
            parseStopTimes(csv: stopTimesCSV)
        }
        if let calendarCSV = await loader.extractFile(from: data, named: "calendar.txt") {
            parseCalendar(csv: calendarCSV)
        }
        if let shapesCSV = await loader.extractFile(from: data, named: "shapes.txt") {
            parseShapes(csv: shapesCSV)
        }
        if let routesCSV = await loader.extractFile(from: data, named: "routes.txt") {
            parseRoutes(csv: routesCSV)
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

        guard let stmt = db.prepareInsertTrip() else { return }
        db.beginTransaction()

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(tripIdx, routeIdx, serviceIdx) else { continue }
            let tripId = fields[tripIdx]
            guard !tripId.isEmpty else { continue }
            let routeId = fields[routeIdx]
            let dir = dirIdx.flatMap { fields.count > $0 ? Int(fields[$0]) : nil } ?? 0
            let shape = shapeIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""

            // Bind: trip_id, route_id, service_id, direction_id, route_short_name, shape_id
            sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (routeId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (fields[serviceIdx] as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(dir))
            let routeName = routeLookup[routeId] ?? routeId
            sqlite3_bind_text(stmt, 5, (routeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (shape as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        db.commitTransaction()
        db.finalize(stmt)
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

        // INSERT INTO stop_times (trip_id, stop_id, arrival_seconds, departure_seconds, stop_sequence, departure_time)
        guard let stmt = db.prepareInsertStopTime() else { return }
        db.beginTransaction()

        var count = 0
        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(tripIdx, stopIdx, arrIdx, depIdx, seqIdx) else { continue }
            let tripId = fields[tripIdx]
            let stopId = fields[stopIdx]
            guard !tripId.isEmpty, !stopId.isEmpty else { continue }

            let depTime = fields[depIdx]
            let arrTime = fields[arrIdx]
            let arrSec = timeToSeconds(arrTime)
            let depSec = timeToSeconds(depTime)
            let seq = Int(fields[seqIdx]) ?? 0

            // Bind all 6 columns: trip_id, stop_id, arrival_seconds, departure_seconds, stop_sequence, departure_time
            sqlite3_bind_text(stmt, 1, (tripId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (stopId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(arrSec))
            sqlite3_bind_int(stmt, 4, Int32(depSec))
            sqlite3_bind_int(stmt, 5, Int32(seq))
            sqlite3_bind_text(stmt, 6, (depTime as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)

            count += 1
            if count % 100_000 == 0 {
                db.commitTransaction()
                db.beginTransaction()
            }
        }

        db.commitTransaction()
        db.finalize(stmt)
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

        guard let stmt = db.prepareInsertCalendar() else { return }
        db.beginTransaction()

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(sidIdx, sunIdx) else { continue }
            let serviceId = fields[sidIdx]
            guard !serviceId.isEmpty else { continue }

            // Bind: service_id, monday..sunday (7 ints)
            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, fields[monIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 3, fields[tueIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 4, fields[wedIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 5, fields[thuIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 6, fields[friIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 7, fields[satIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 8, fields[sunIdx] == "1" ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        db.commitTransaction()
        db.finalize(stmt)
    }

    private func timeToSeconds(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private func parseShapes(csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return }
        let headers = header.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        guard let idIdx = headers.firstIndex(of: "shape_id"),
              let latIdx = headers.firstIndex(of: "shape_pt_lat"),
              let lonIdx = headers.firstIndex(of: "shape_pt_lon"),
              let seqIdx = headers.firstIndex(of: "shape_pt_sequence") else { return }

        let maxIdx = max(idIdx, latIdx, lonIdx, seqIdx)
        guard let stmt = db.prepareInsertShape() else { return }
        db.beginTransaction()

        var count = 0
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > maxIdx else { continue }
            let shapeId = fields[idIdx]
            guard !shapeId.isEmpty,
                  let lat = Double(fields[latIdx]),
                  let lon = Double(fields[lonIdx]),
                  let seq = Int(fields[seqIdx]) else { continue }

            sqlite3_bind_text(stmt, 1, (shapeId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, lat)
            sqlite3_bind_double(stmt, 3, lon)
            sqlite3_bind_int(stmt, 4, Int32(seq))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)

            count += 1
            if count % 100_000 == 0 {
                db.commitTransaction()
                db.beginTransaction()
            }
        }

        db.commitTransaction()
        db.finalize(stmt)
    }

    private func parseRoutes(csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return }
        let headers = parseCSVRow(header)

        guard let idIdx = headers.firstIndex(of: "route_id") else { return }
        let nameIdx = headers.firstIndex(of: "route_short_name")
        let longNameIdx = headers.firstIndex(of: "route_long_name")
        let typeIdx = headers.firstIndex(of: "route_type")

        guard let stmt = db.prepareInsertRoute() else { return }
        db.beginTransaction()

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > idIdx else { continue }
            let routeId = fields[idIdx]
            guard !routeId.isEmpty else { continue }

            let shortName = nameIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            let longName = longNameIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            let routeType = typeIdx.flatMap { fields.count > $0 ? Int(fields[$0]) : nil } ?? 3

            sqlite3_bind_text(stmt, 1, (routeId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (shortName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (longName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(routeType))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        db.commitTransaction()
        db.finalize(stmt)
    }

    private func parseCSVRow(_ row: String) -> [String] {
        // Strip BOM if present (common in CSV files, breaks header matching)
        let cleanRow = row.hasPrefix("\u{FEFF}") ? String(row.dropFirst()) : row
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in cleanRow {
            if char == "\"" { inQuotes.toggle() }
            else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else { current.append(char) }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}

// MARK: - Expose ZIP extraction from GTFSStopLoader

extension GTFSStopLoader {
    func extractFile(from data: Data, named fileName: String) -> String? {
        extractFileFromZip(data: data, fileName: fileName)
    }
}
