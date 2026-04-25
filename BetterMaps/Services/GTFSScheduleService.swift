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

    let db = GTFSDatabase()

    /// Expose database for RAPTOR engine to build data structures
    var database: GTFSDatabase { db }
    private var isLoaded = false

    /// Weekday column names for SQL calendar queries
    private static let weekdayColumns = [
        "", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"
    ]

    /// Irish timezone calendar for all GTFS date/time operations
    private static let irishCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Dublin")!
        return cal
    }()

    /// Format a Date as GTFS date string (YYYYMMDD) in Irish timezone
    private func formatGTFSDate(_ date: Date) -> String {
        let cal = Self.irishCalendar
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        return String(format: "%04d%02d%02d", y, m, d)
    }

    /// Compute active service IDs for a given date (OTP-style).
    /// Checks calendar.txt (weekday + date range) then applies calendar_dates.txt exceptions.
    func activeServiceIds(for date: Date) async -> Set<String> {
        let cal = Self.irishCalendar
        let weekday = cal.component(.weekday, from: date)
        let weekdayCol = Self.weekdayColumns[weekday]
        let dateStr = formatGTFSDate(date)

        let calendarCount = db.count(table: "calendars")
        let calendarDatesCount = db.count(table: "calendar_dates")

        var baseCount = 0
        var addedCount = 0
        var removedCount = 0
        var services = Set<String>()

        // 1. Base services: weekday=1 AND today within [start_date, end_date]
        let baseSql = """
            SELECT service_id FROM calendars
            WHERE \(weekdayCol) = 1 AND start_date <= ? AND end_date >= ?
        """
        if let stmt = db.prepare(baseSql) {
            sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (dateStr as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let sid = db.columnText(stmt, index: 0) { services.insert(sid) }
            }
            db.finalize(stmt)
        }
        baseCount = services.count

        // 2. Add services from calendar_dates (exception_type=1)
        let addSql = "SELECT service_id FROM calendar_dates WHERE date = ? AND exception_type = 1"
        if let stmt = db.prepare(addSql) {
            sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let sid = db.columnText(stmt, index: 0) { services.insert(sid) }
            }
            db.finalize(stmt)
        }
        addedCount = services.count - baseCount

        // 3. Remove services from calendar_dates (exception_type=2)
        let beforeRemove = services.count
        let removeSql = "SELECT service_id FROM calendar_dates WHERE date = ? AND exception_type = 2"
        if let stmt = db.prepare(removeSql) {
            sqlite3_bind_text(stmt, 1, (dateStr as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let sid = db.columnText(stmt, index: 0) { services.remove(sid) }
            }
            db.finalize(stmt)
        }
        removedCount = beforeRemove - services.count

        await APILogger.shared.log(
            service: "GTFS", endpoint: "activeServiceIds",
            status: services.isEmpty ? .failure : .success, durationMs: 0,
            detail: "date=\(dateStr) weekday=\(weekdayCol) | base:\(baseCount) +added:\(addedCount) -removed:\(removedCount) = \(services.count) active"
        )

        return services
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard !isLoaded else { return }

        // Check if SQLite database is fresh AND has data
        if GTFSDatabase.isFresh {
            if db.open() {
                let trips = db.count(table: "trips")
                let shapes = db.count(table: "shapes")
                // Both must be populated. A DB with trips but zero shapes is the
                // signature of the BOM-affected parseShapes header miss — accept
                // it and the Luas/DART/Rail polylines never render. Force a
                // re-parse so users on broken caches recover without waiting for
                // the 7-day freshness window to lapse.
                if trips > 0 && shapes > 0 {
                    isLoaded = true
                    await APILogger.shared.log(service: "TFI", endpoint: "GTFS schedule (SQLite)", status: .cached, durationMs: 0, detail: "\(trips) trips, \(shapes) shapes")
                    return
                }
                let reason = trips == 0 ? "0 trips" : "\(trips) trips but 0 shapes"
                db.close()
                try? FileManager.default.removeItem(atPath: GTFSDatabase.defaultPath)
                await APILogger.shared.log(service: "TFI", endpoint: "GTFS schedule (SQLite)", status: .failure, durationMs: 0, detail: "Cached DB has \(reason) — re-parsing")
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
    /// Uses pre-computed active service IDs (from activeServiceIds()) instead of
    /// JOIN on calendars — faster and correctly handles calendar_dates exceptions.
    func departuresFromStop(stopId: String, afterSeconds: Int, withinSeconds: Int = 1200,
                            activeServices: Set<String>) -> [(GTFSStopTime, GTFSTrip)] {
        guard !activeServices.isEmpty else { return [] }
        let upperBound = afterSeconds + withinSeconds
        let placeholders = activeServices.map { _ in "?" }.joined(separator: ",")

        let sql = """
            SELECT st.trip_id, st.stop_id, st.departure_seconds, st.stop_sequence, st.departure_time,
                   t.route_id, t.service_id, t.direction_id, t.route_short_name, t.shape_id,
                   COALESCE(r.route_type, 3)
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            LEFT JOIN routes r ON t.route_id = r.route_id
            WHERE st.stop_id = ? AND st.departure_seconds >= ? AND st.departure_seconds <= ?
            AND t.service_id IN (\(placeholders))
            ORDER BY st.departure_seconds
            LIMIT 50
        """

        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (stopId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(afterSeconds))
        sqlite3_bind_int(stmt, 3, Int32(upperBound))
        // Bind active service IDs starting at parameter index 4
        for (i, serviceId) in activeServices.enumerated() {
            sqlite3_bind_text(stmt, Int32(4 + i), (serviceId as NSString).utf8String, -1, nil)
        }

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

    /// Search routes by short name (e.g. "39A", "DART", "Green").
    /// Returns matching routes for the search bar.
    func searchRoutes(query: String) -> [(routeId: String, routeName: String, longName: String, routeType: Int)] {
        let sql = """
            SELECT route_id, route_short_name, route_long_name, route_type
            FROM routes
            WHERE UPPER(route_short_name) LIKE '%' || UPPER(?) || '%'
               OR UPPER(route_long_name) LIKE '%' || UPPER(?) || '%'
            ORDER BY route_short_name
            LIMIT 10
        """
        guard let stmt = db.prepare(sql) else { return [] }
        defer { db.finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (query as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (query as NSString).utf8String, -1, nil)

        var results: [(String, String, String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                db.columnText(stmt, index: 0) ?? "",
                db.columnText(stmt, index: 1) ?? "",
                db.columnText(stmt, index: 2) ?? "",
                db.columnInt(stmt, index: 3)
            ))
        }
        return results
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

    /// Maps Luas stop IDs to their line color. Mirror of luasShapesByLine but
    /// for stops, so the map can give Red-line pins the red Luas color and
    /// Green-line pins the green Luas color (matching what DART and Rail
    /// already do — pin hue matches the line you'd ride from there).
    /// Interchange stops served by both lines fall into both sets; the map
    /// view picks Red on overlap to make the rarer Red presence stand out.
    func luasStopsByLine() -> (red: Set<String>, green: Set<String>) {
        let sql = """
            SELECT DISTINCT st.stop_id, LOWER(COALESCE(r.route_short_name, '') || ' ' || COALESCE(r.route_long_name, ''))
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 0
        """
        guard let stmt = db.prepare(sql) else { return ([], []) }
        defer { db.finalize(stmt) }

        var red = Set<String>()
        var green = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let stopId = db.columnText(stmt, index: 0),
                  let names = db.columnText(stmt, index: 1) else { continue }
            if names.contains("red") {
                red.insert(stopId)
            } else {
                green.insert(stopId)
            }
        }
        return (red, green)
    }

    /// Luas shapes split by line color. Returns (red, green) shape arrays.
    /// Uses DISTINCT shape_id to capture all branches (e.g. Red Line Tallaght + Saggart).
    /// Identifies Red vs Green by route_short_name or route_long_name.
    func luasShapesByLine() -> (red: [[CLLocationCoordinate2D]], green: [[CLLocationCoordinate2D]]) {
        let sql = """
            SELECT DISTINCT t.shape_id, LOWER(COALESCE(r.route_short_name, '') || ' ' || COALESCE(r.route_long_name, ''))
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 0 AND t.shape_id != ''
        """
        guard let stmt = db.prepare(sql) else { return ([], []) }
        defer { db.finalize(stmt) }

        var redIds: [String] = []
        var greenIds: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let shapeId = db.columnText(stmt, index: 0),
                  let names = db.columnText(stmt, index: 1) else { continue }
            if names.contains("red") {
                redIds.append(shapeId)
            } else {
                greenIds.append(shapeId)
            }
        }

        let red = redIds.compactMap { id -> [CLLocationCoordinate2D]? in
            let coords = shapeCoordinates(for: id)
            return coords.count >= 2 ? coords : nil
        }
        let green = greenIds.compactMap { id -> [CLLocationCoordinate2D]? in
            let coords = shapeCoordinates(for: id)
            return coords.count >= 2 ? coords : nil
        }
        return (red, green)
    }

    /// Shape coordinates for DART routes only (route_short_name = 'DART').
    /// DART has multiple branches (Howth + Malahide) sharing the same route_id,
    /// so we get all distinct shapes rather than one per direction.
    func shapeCoordinatesForDART() -> [[CLLocationCoordinate2D]] {
        let sql = """
            SELECT DISTINCT t.shape_id
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 2 AND UPPER(r.route_short_name) = 'DART' AND t.shape_id != ''
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
    /// Uses DISTINCT shape_id to capture branch lines (e.g. Westport/Ballina
    /// split at Manulla Junction but share a route_id).
    func shapeCoordinatesForNonDartRail() -> [[CLLocationCoordinate2D]] {
        let sql = """
            SELECT DISTINCT t.shape_id
            FROM trips t
            JOIN routes r ON t.route_id = r.route_id
            WHERE r.route_type = 2 AND UPPER(r.route_short_name) != 'DART' AND t.shape_id != ''
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
        // stop_times.txt is the largest file (~500–800 MB uncompressed). Parse it from
        // raw Data via streaming line iteration to avoid the giant String/[String] copies
        // that push us past the iOS per-process memory limit on a fresh install.
        if let stopTimesData = await loader.extractFileData(from: data, named: "stop_times.txt") {
            parseStopTimes(data: stopTimesData)
        }
        if let calendarCSV = await loader.extractFile(from: data, named: "calendar.txt") {
            parseCalendar(csv: calendarCSV)
        }
        if let calendarDatesCSV = await loader.extractFile(from: data, named: "calendar_dates.txt") {
            parseCalendarDates(csv: calendarDatesCSV)
        }
        // shapes.txt is the second-largest (~50–100 MB). Same streaming treatment.
        if let shapesData = await loader.extractFileData(from: data, named: "shapes.txt") {
            parseShapes(data: shapesData)
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

    /// Streams stop_times.txt line-by-line directly from Data to avoid allocating the
    /// full ~500–800 MB String and a second ~500 MB array-of-lines. Peak overhead is
    /// one line's worth of memory.
    ///
    /// Deliberately avoids `data.withUnsafeBytes { ... }` and any other closure-taking
    /// helper: this runs on the GTFSScheduleService actor, and capturing the mutable
    /// SQLite `stmt` pointer inside a closure passed to a nonisolated function trips
    /// Swift 6's region-based isolation analysis ("Sending 'stmt' risks data races"),
    /// because OpaquePointer isn't Sendable. Direct subscript iteration keeps stmt
    /// entirely within the actor method's body.
    private func parseStopTimes(data: Data) {
        guard let stmt = db.prepareInsertStopTime() else { return }
        defer { db.finalize(stmt) }

        var tripIdx = -1, stopIdx = -1, arrIdx = -1, depIdx = -1, seqIdx = -1
        var maxIdx = -1
        var headerSeen = false
        var transactionOpen = false
        var count = 0

        let total = data.count
        var i = 0
        while i < total {
            // Scan to end of current line
            var end = i
            while end < total {
                let b = data[end]
                if b == 0x0A || b == 0x0D { break }
                end += 1
            }

            if end > i {
                // Decode a single line's UTF-8 bytes (invalid bytes become U+FFFD —
                // fine for CSV that's expected to be ASCII/UTF-8).
                let line = String(decoding: data[i..<end], as: UTF8.self)

                if !headerSeen {
                    headerSeen = true
                    let headers = parseCSVRow(line)
                    if let t = headers.firstIndex(of: "trip_id"),
                       let s = headers.firstIndex(of: "stop_id"),
                       let a = headers.firstIndex(of: "arrival_time"),
                       let d = headers.firstIndex(of: "departure_time"),
                       let q = headers.firstIndex(of: "stop_sequence") {
                        tripIdx = t; stopIdx = s; arrIdx = a; depIdx = d; seqIdx = q
                        maxIdx = max(tripIdx, stopIdx, arrIdx, depIdx, seqIdx)
                        db.beginTransaction()
                        transactionOpen = true
                    }
                } else if maxIdx >= 0 {
                    let fields = parseCSVRow(line)
                    if fields.count > maxIdx {
                        let tripId = fields[tripIdx]
                        let stopId = fields[stopIdx]
                        if !tripId.isEmpty, !stopId.isEmpty {
                            let depTime = fields[depIdx]
                            let arrTime = fields[arrIdx]
                            let arrSec = timeToSeconds(arrTime)
                            let depSec = timeToSeconds(depTime)
                            let seq = Int(fields[seqIdx]) ?? 0

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
                    }
                }
            }

            // Advance past line terminator (CR, LF, or CRLF)
            if end < total && data[end] == 0x0D { end += 1 }
            if end < total && data[end] == 0x0A { end += 1 }
            i = end
        }

        if transactionOpen {
            db.commitTransaction()
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

        guard let stmt = db.prepareInsertCalendar() else { return }
        db.beginTransaction()

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(sidIdx, sunIdx) else { continue }
            let serviceId = fields[sidIdx]
            guard !serviceId.isEmpty else { continue }

            let startDate = startIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            let endDate = endIdx.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""

            // Bind: service_id, mon-sun (7 ints), start_date, end_date
            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, fields[monIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 3, fields[tueIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 4, fields[wedIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 5, fields[thuIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 6, fields[friIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 7, fields[satIdx] == "1" ? 1 : 0)
            sqlite3_bind_int(stmt, 8, fields[sunIdx] == "1" ? 1 : 0)
            sqlite3_bind_text(stmt, 9, (startDate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 10, (endDate as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        db.commitTransaction()
        db.finalize(stmt)
    }

    private func parseCalendarDates(csv: String) {
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return }
        let headers = parseCSVRow(header)

        guard let sidIdx = headers.firstIndex(of: "service_id"),
              let dateIdx = headers.firstIndex(of: "date"),
              let typeIdx = headers.firstIndex(of: "exception_type") else { return }

        guard let stmt = db.prepareInsertCalendarDate() else { return }
        db.beginTransaction()

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(sidIdx, dateIdx, typeIdx) else { continue }
            let serviceId = fields[sidIdx]
            let date = fields[dateIdx]
            guard !serviceId.isEmpty, !date.isEmpty else { continue }
            let exceptionType = Int(fields[typeIdx]) ?? 0

            sqlite3_bind_text(stmt, 1, (serviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (date as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(exceptionType))
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

    /// Streams shapes.txt from raw Data. Same rationale as parseStopTimes — see the
    /// comment there for why iteration is inlined with subscript access instead of
    /// `withUnsafeBytes`.
    private func parseShapes(data: Data) {
        guard let stmt = db.prepareInsertShape() else { return }
        defer { db.finalize(stmt) }

        var idIdx = -1, latIdx = -1, lonIdx = -1, seqIdx = -1
        var maxIdx = -1
        var headerSeen = false
        var transactionOpen = false
        var count = 0

        let total = data.count
        var i = 0
        while i < total {
            var end = i
            while end < total {
                let b = data[end]
                if b == 0x0A || b == 0x0D { break }
                end += 1
            }

            if end > i {
                let line = String(decoding: data[i..<end], as: UTF8.self)

                if !headerSeen {
                    headerSeen = true
                    // parseCSVRow strips the UTF-8 BOM (0xEF 0xBB 0xBF / U+FEFF) that
                    // TFI's shapes.txt occasionally ships with. The previous bare
                    // line.split path didn't, so the first header read as
                    // "\u{FEFF}shape_id", firstIndex(of: "shape_id") returned nil,
                    // maxIdx stayed -1, and the whole shapes table silently parsed
                    // zero rows — which manifested as no Luas/DART/Rail polylines
                    // even though stops/trips/routes loaded fine.
                    let headers = parseCSVRow(line)
                    if let h = headers.firstIndex(of: "shape_id"),
                       let la = headers.firstIndex(of: "shape_pt_lat"),
                       let lo = headers.firstIndex(of: "shape_pt_lon"),
                       let sq = headers.firstIndex(of: "shape_pt_sequence") {
                        idIdx = h; latIdx = la; lonIdx = lo; seqIdx = sq
                        maxIdx = max(idIdx, latIdx, lonIdx, seqIdx)
                        db.beginTransaction()
                        transactionOpen = true
                    }
                } else if maxIdx >= 0 {
                    let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                    if fields.count > maxIdx {
                        let shapeId = fields[idIdx]
                        if !shapeId.isEmpty,
                           let lat = Double(fields[latIdx]),
                           let lon = Double(fields[lonIdx]),
                           let seq = Int(fields[seqIdx]) {
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
                    }
                }
            }

            if end < total && data[end] == 0x0D { end += 1 }
            if end < total && data[end] == 0x0A { end += 1 }
            i = end
        }

        if transactionOpen {
            db.commitTransaction()
        }
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

    func extractFileData(from data: Data, named fileName: String) -> Data? {
        extractFileDataFromZip(data: data, fileName: fileName)
    }
}

// MARK: - Transit Shape Disk Cache

/// Persists Luas/DART/Rail polyline arrays to JSON in the caches directory so the
/// map renders lines instantly on launch — even before the SQLite GTFS DB has
/// finished opening, and even if the GTFS feed is unreachable. Without this
/// cache the polyline arrays start empty every launch and only populate after
/// loadIfNeeded() + per-line SQL queries return, which is what made Luas/DART
/// lines vanish intermittently after a fresh install or when the feed was slow.
enum TransitShapeCache {
    struct Snapshot: Codable {
        var luasRed: [[Coord]]
        var luasGreen: [[Coord]]
        var dart: [[Coord]]
        var rail: [[Coord]]
        // Luas stop IDs by line. Optional in the codable to stay backward-
        // compatible with caches written before this field existed — those
        // decode to nil here and the map view falls back to the default
        // green Luas pin color until SQLite catches up.
        var luasRedStops: [String]?
        var luasGreenStops: [String]?

        struct Coord: Codable {
            let lat: Double
            let lon: Double
        }
    }

    private static let fileName = "gtfs_shapes_cache.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    /// Synchronous read so callers can populate state before the first body recompute.
    static func load() -> (red: [[CLLocationCoordinate2D]],
                          green: [[CLLocationCoordinate2D]],
                          dart: [[CLLocationCoordinate2D]],
                          rail: [[CLLocationCoordinate2D]],
                          luasRedStops: Set<String>,
                          luasGreenStops: Set<String>)? {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        let red = snap.luasRed.map { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        let green = snap.luasGreen.map { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        let dart = snap.dart.map { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        let rail = snap.rail.map { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        let redStops = Set(snap.luasRedStops ?? [])
        let greenStops = Set(snap.luasGreenStops ?? [])
        return (red, green, dart, rail, redStops, greenStops)
    }

    static func save(luasRed: [[CLLocationCoordinate2D]],
                     luasGreen: [[CLLocationCoordinate2D]],
                     dart: [[CLLocationCoordinate2D]],
                     rail: [[CLLocationCoordinate2D]],
                     luasRedStops: Set<String>,
                     luasGreenStops: Set<String>) {
        // Refuse to write an empty snapshot — that would clobber a good cache when
        // the SQLite query temporarily returns nothing (mid-rebuild, partial parse).
        guard !luasRed.isEmpty || !luasGreen.isEmpty || !dart.isEmpty || !rail.isEmpty else { return }
        let snap = Snapshot(
            luasRed: luasRed.map { $0.map { Snapshot.Coord(lat: $0.latitude, lon: $0.longitude) } },
            luasGreen: luasGreen.map { $0.map { Snapshot.Coord(lat: $0.latitude, lon: $0.longitude) } },
            dart: dart.map { $0.map { Snapshot.Coord(lat: $0.latitude, lon: $0.longitude) } },
            rail: rail.map { $0.map { Snapshot.Coord(lat: $0.latitude, lon: $0.longitude) } },
            luasRedStops: Array(luasRedStops),
            luasGreenStops: Array(luasGreenStops)
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
