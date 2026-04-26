import Foundation
import SQLite3

// MARK: - Transit Graph Data Model

/// Compact pre-computed transit graph for instant route planning.
/// Built from GTFS SQLite at install time, cached as JSON (~450 KB).
/// Enables O(1) travel time lookups and ~5ms Dijkstra searches.

struct RouteTravelData: Codable {
    let routeId: String
    let routeName: String
    let routeLongName: String  // e.g. "Dublin - Maynooth", "Bray - Howth"
    let routeType: Int  // 0=luas/tram, 2=rail/dart, 3=bus
    let directionId: Int
    let stopIds: [String]  // ordered by stop_sequence

    /// Cumulative seconds from first stop, by time bucket.
    /// Buckets: 0=AM peak (7-9:30), 1=midday (9:30-16), 2=PM peak (16-18:30),
    ///          3=evening (18:30-22), 4=night (22-7)
    /// Lookup: travel(A→B) = cumulativeSeconds[bucket][idxB] - cumulativeSeconds[bucket][idxA]
    let cumulativeSeconds: [[UInt16]]  // [5 buckets][N stops]

    /// Headway (seconds between departures) per time bucket
    let headways: [UInt16]  // [5 buckets]
    let firstDeparture: UInt16  // minutes since midnight
    let lastDeparture: UInt16   // minutes since midnight
}

struct WalkTransfer: Codable {
    let fromStopIndex: Int
    let toStopIndex: Int
    let walkSeconds: UInt16
}

struct TransitGraph: Codable {
    let routes: [RouteTravelData]
    let transfers: [WalkTransfer]
    let stopIds: [String]              // index → stop_id
    let stopIdToIndex: [String: Int]   // stop_id → index
    let stopLats: [Float]              // index → latitude
    let stopLons: [Float]              // index → longitude
    let buildDate: String              // YYYYMMDD
    let serviceDay: String             // "weekday" or "saturday" or "sunday"
    let buildTimestamp: TimeInterval    // for staleness display
    var version: Int = 0               // graph format version for cache invalidation (0 = pre-versioning)

    /// Time bucket for a given seconds-since-midnight
    static func timeBucket(for seconds: Int) -> Int {
        switch seconds {
        case 25200..<34200: return 0  // AM peak 7:00-9:30
        case 34200..<57600: return 1  // Midday 9:30-16:00
        case 57600..<66600: return 2  // PM peak 16:00-18:30
        case 66600..<79200: return 3  // Evening 18:30-22:00
        default: return 4             // Night 22:00-7:00
        }
    }

    /// Staleness description for display
    var stalenessLabel: String {
        let age = Int(Date().timeIntervalSince1970 - buildTimestamp)
        if age < 3600 { return "\(serviceDay) timetable" }
        if age < 86400 { return "\(serviceDay) timetable · \(age / 3600)h ago" }
        return "\(serviceDay) timetable · \(age / 86400)d ago"
    }
}

// MARK: - Transit Graph Builder

/// Builds a compact transit graph from GTFS SQLite data.
/// Called once at install time and when GTFS data refreshes.
actor TransitGraphBuilder {

    private static let cacheURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transit_graph.json")
    }()

    /// Graph format version — increment to invalidate old caches after structural fixes.
    /// v2: Fixed stop ordering using GTFS stop_sequence instead of segment chaining.
    /// v3: Added routeLongName for descriptive rail route names.
    private static let graphVersion = 3

    /// Load cached graph if fresh, correct version, non-empty, and matches
    /// today's service day. nil triggers a rebuild from SQLite.
    static func loadCached() -> TransitGraph? {
        guard let data = try? Data(contentsOf: cacheURL),
              let graph = try? JSONDecoder().decode(TransitGraph.self, from: data) else { return nil }
        if graph.version != graphVersion { return nil }
        if Date().timeIntervalSince1970 - graph.buildTimestamp > 7 * 24 * 3600 { return nil }
        // Empty graphs are never useful — they get produced when build() runs
        // before stops or services are populated (e.g., first-launch race
        // condition during initial GTFS download). Trash and rebuild so the
        // user doesn't sit on an empty graph for 7 days.
        if graph.routes.isEmpty { return nil }
        // Service-day mismatch: a graph built on Saturday includes only
        // Saturday's routes. Sunday's routing query uses Sunday's active
        // services, which won't match anything in a Saturday graph and the
        // user gets zero results. Rebuild whenever the day's service type
        // changes.
        if graph.serviceDay != currentServiceDay() { return nil }
        return graph
    }

    /// "weekday", "saturday", or "sunday" for today in Europe/Dublin —
    /// matches the value `build()` writes into TransitGraph.serviceDay.
    static func currentServiceDay() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Dublin")!
        let weekday = cal.component(.weekday, from: Date())
        return weekday == 1 ? "sunday" : weekday == 7 ? "saturday" : "weekday"
    }

    /// Build the transit graph from GTFS SQLite
    func build(db: GTFSDatabase, activeServices: Set<String>, allStops: [TransitStop]) async -> TransitGraph {
        let start = Date()

        // 1. Build stop index
        var stopIds: [String] = []
        var stopIdToIndex: [String: Int] = [:]
        var stopLats: [Float] = []
        var stopLons: [Float] = []
        for stop in allStops {
            let idx = stopIds.count
            stopIds.append(stop.id)
            stopIdToIndex[stop.id] = idx
            stopLats.append(Float(stop.latitude))
            stopLons.append(Float(stop.longitude))
        }

        let serviceList = activeServices.map { "'\($0)'" }.joined(separator: ",")
        struct RouteKey: Hashable { let routeId: String; let directionId: Int }

        // 2. Get authoritative stop order from GTFS stop_times.
        // Step 1: Find the longest trip per route/direction (most stops = covers branches)
        let longestTripSQL = """
            SELECT t.route_id, t.direction_id, t.trip_id, COUNT(*) as stop_count,
                   COALESCE(r.route_type, 3), COALESCE(r.route_short_name, ''),
                   COALESCE(r.route_long_name, '')
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            LEFT JOIN routes r ON t.route_id = r.route_id
            WHERE t.service_id IN (\(serviceList))
            GROUP BY t.route_id, t.direction_id, t.trip_id
            ORDER BY t.route_id, t.direction_id, stop_count DESC
        """

        var canonicalTripId: [RouteKey: String] = [:]
        var routeMeta: [RouteKey: (type: Int, name: String, longName: String)] = [:]

        if let stmt = db.prepare(longestTripSQL) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let routeId = db.columnText(stmt, index: 0) ?? ""
                let dirId = db.columnInt(stmt, index: 1)
                let tripId = db.columnText(stmt, index: 2) ?? ""
                let routeType = db.columnInt(stmt, index: 4)
                let routeName = db.columnText(stmt, index: 5) ?? ""
                let routeLongName = db.columnText(stmt, index: 6) ?? ""

                let key = RouteKey(routeId: routeId, directionId: dirId)
                if canonicalTripId[key] == nil {
                    canonicalTripId[key] = tripId
                    routeMeta[key] = (routeType, routeName, routeLongName)
                }
            }
            db.finalize(stmt)
        }

        // Step 2: Get the stop sequence for just those canonical trips
        let tripList = canonicalTripId.values.map { "'\($0)'" }.joined(separator: ",")
        let stopOrderSQL = """
            SELECT t.route_id, t.direction_id, st.stop_id, st.stop_sequence
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            WHERE t.trip_id IN (\(tripList))
            ORDER BY t.route_id, t.direction_id, st.stop_sequence
        """

        var canonicalStopOrder: [RouteKey: [String]] = [:]

        if let stmt = db.prepare(stopOrderSQL) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let routeId = db.columnText(stmt, index: 0) ?? ""
                let dirId = db.columnInt(stmt, index: 1)
                let stopId = db.columnText(stmt, index: 2) ?? ""

                let key = RouteKey(routeId: routeId, directionId: dirId)
                canonicalStopOrder[key, default: []].append(stopId)
            }
            db.finalize(stmt)
        }

        // 3. Compute segment travel times per route/direction/bucket
        let segmentSQL = """
            SELECT t.route_id, t.direction_id, st1.stop_id, st2.stop_id,
                CASE
                    WHEN st1.departure_seconds BETWEEN 25200 AND 34199 THEN 0
                    WHEN st1.departure_seconds BETWEEN 34200 AND 57599 THEN 1
                    WHEN st1.departure_seconds BETWEEN 57600 AND 66599 THEN 2
                    WHEN st1.departure_seconds BETWEEN 66600 AND 79199 THEN 3
                    ELSE 4
                END AS bucket,
                AVG(st2.arrival_seconds - st1.departure_seconds) AS avg_sec
            FROM stop_times st1
            JOIN stop_times st2 ON st1.trip_id = st2.trip_id AND st2.stop_sequence = st1.stop_sequence + 1
            JOIN trips t ON st1.trip_id = t.trip_id
            WHERE t.service_id IN (\(serviceList))
            GROUP BY t.route_id, t.direction_id, st1.stop_id, st2.stop_id, bucket
        """

        // route_id+dir → bucket → [(fromStop, toStop, avgSec)]
        var segmentsByRoute: [RouteKey: [Int: [(from: String, to: String, sec: Int)]]] = [:]

        if let stmt = db.prepare(segmentSQL) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let routeId = db.columnText(stmt, index: 0) ?? ""
                let dirId = db.columnInt(stmt, index: 1)
                let fromStop = db.columnText(stmt, index: 2) ?? ""
                let toStop = db.columnText(stmt, index: 3) ?? ""
                let bucket = db.columnInt(stmt, index: 4)
                let avgSec = db.columnInt(stmt, index: 5)

                let key = RouteKey(routeId: routeId, directionId: dirId)
                segmentsByRoute[key, default: [:]][bucket, default: []].append((fromStop, toStop, max(avgSec, 1)))
            }
            db.finalize(stmt)
        }

        // 3. Compute headways per route/direction/bucket
        let headwaySQL = """
            SELECT t.route_id, t.direction_id,
                CASE
                    WHEN st.departure_seconds BETWEEN 25200 AND 34199 THEN 0
                    WHEN st.departure_seconds BETWEEN 34200 AND 57599 THEN 1
                    WHEN st.departure_seconds BETWEEN 57600 AND 66599 THEN 2
                    WHEN st.departure_seconds BETWEEN 66600 AND 79199 THEN 3
                    ELSE 4
                END AS bucket,
                COUNT(DISTINCT st.trip_id),
                MIN(st.departure_seconds),
                MAX(st.departure_seconds)
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            WHERE t.service_id IN (\(serviceList)) AND st.stop_sequence = 1
            GROUP BY t.route_id, t.direction_id, bucket
        """

        var headwaysByRoute: [RouteKey: [Int: UInt16]] = [:]  // bucket → headway seconds
        var firstLastByRoute: [RouteKey: (first: Int, last: Int)] = [:]

        if let stmt = db.prepare(headwaySQL) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let routeId = db.columnText(stmt, index: 0) ?? ""
                let dirId = db.columnInt(stmt, index: 1)
                let bucket = db.columnInt(stmt, index: 2)
                let tripCount = db.columnInt(stmt, index: 3)
                let minDep = db.columnInt(stmt, index: 4)
                let maxDep = db.columnInt(stmt, index: 5)

                let key = RouteKey(routeId: routeId, directionId: dirId)
                let headway = tripCount > 1 ? UInt16(min(65535, (maxDep - minDep) / (tripCount - 1))) : UInt16(3600)
                headwaysByRoute[key, default: [:]][bucket] = headway

                let existing = firstLastByRoute[key]
                firstLastByRoute[key] = (
                    min(existing?.first ?? minDep, minDep),
                    max(existing?.last ?? maxDep, maxDep)
                )
            }
            db.finalize(stmt)
        }

        // 4. Build RouteTravelData for each route/direction
        var routes: [RouteTravelData] = []

        for (key, bucketSegments) in segmentsByRoute {
            guard let meta = routeMeta[key] else { continue }

            // Use authoritative stop order from GTFS stop_sequence
            guard let stopOrder = canonicalStopOrder[key], stopOrder.count >= 2 else { continue }

            // Build cumulative seconds per bucket
            var cumulativeSeconds: [[UInt16]] = []
            for bucket in 0..<5 {
                let segments = bucketSegments[bucket] ?? []
                let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ("\($0.from)→\($0.to)", $0.sec) })

                var cumulative: [UInt16] = [0]  // First stop = 0
                for i in 1..<stopOrder.count {
                    let segKey = "\(stopOrder[i-1])→\(stopOrder[i])"
                    let segTime = segmentMap[segKey] ?? 120  // Default 2 min if missing
                    let prev = Int(cumulative[i-1])
                    cumulative.append(UInt16(min(65535, prev + segTime)))
                }
                cumulativeSeconds.append(cumulative)
            }

            // Headways
            let headways: [UInt16] = (0..<5).map { headwaysByRoute[key]?[$0] ?? 1800 }
            let fl = firstLastByRoute[key] ?? (25200, 79200)

            routes.append(RouteTravelData(
                routeId: key.routeId,
                routeName: meta.name,
                routeLongName: meta.longName,
                routeType: meta.type,
                directionId: key.directionId,
                stopIds: stopOrder,
                cumulativeSeconds: cumulativeSeconds,
                headways: headways,
                firstDeparture: UInt16(fl.first / 60),
                lastDeparture: UInt16(fl.last / 60)
            ))
        }

        // 5. Build walking transfers (stops within 300m)
        var transfers: [WalkTransfer] = []
        let gridSize = 0.003
        var grid: [String: [(idx: Int, lat: Double, lon: Double)]] = [:]
        for (i, stop) in allStops.enumerated() {
            let key = "\(Int(stop.latitude / gridSize)),\(Int(stop.longitude / gridSize))"
            grid[key, default: []].append((i, stop.latitude, stop.longitude))
        }

        for (i, stop) in allStops.enumerated() {
            let gx = Int(stop.latitude / gridSize)
            let gy = Int(stop.longitude / gridSize)
            for dx in -1...1 {
                for dy in -1...1 {
                    let key = "\(gx + dx),\(gy + dy)"
                    guard let cell = grid[key] else { continue }
                    for other in cell where other.idx != i {
                        let dist = haversine(lat1: stop.latitude, lon1: stop.longitude,
                                           lat2: other.lat, lon2: other.lon)
                        if dist <= 300 {
                            let walkSec = UInt16(dist * 1.4 / 80 * 60)
                            transfers.append(WalkTransfer(fromStopIndex: i, toStopIndex: other.idx, walkSeconds: walkSec))
                        }
                    }
                }
            }
        }

        // Determine service day type
        var irishCal = Calendar(identifier: .gregorian)
        irishCal.timeZone = TimeZone(identifier: "Europe/Dublin")!
        let weekday = irishCal.component(.weekday, from: Date())
        let serviceDay = weekday == 1 ? "sunday" : weekday == 7 ? "saturday" : "weekday"
        let dateStr = {
            let y = irishCal.component(.year, from: Date())
            let m = irishCal.component(.month, from: Date())
            let d = irishCal.component(.day, from: Date())
            return String(format: "%04d%02d%02d", y, m, d)
        }()

        let graph = TransitGraph(
            routes: routes,
            transfers: transfers,
            stopIds: stopIds,
            stopIdToIndex: stopIdToIndex,
            stopLats: stopLats,
            stopLons: stopLons,
            buildDate: dateStr,
            serviceDay: serviceDay,
            buildTimestamp: Date().timeIntervalSince1970,
            version: Self.graphVersion
        )

        // Save to cache — but only if the build actually produced data.
        // An empty graph is the signature of a race during first launch
        // (stops or activeServices not yet loaded); persisting it would
        // poison the cache for up to 7 days even though SQLite is healthy.
        if !routes.isEmpty,
           let data = try? JSONEncoder().encode(graph) {
            try? data.write(to: Self.cacheURL)
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        await APILogger.shared.log(
            service: "TransitGraph", endpoint: "build",
            status: routes.isEmpty ? .failure : .success, durationMs: ms,
            detail: "\(routes.count) routes, \(transfers.count) transfers, \(stopIds.count) stops, services=\(activeServices.count). \(ms)ms"
        )

        return graph
    }

    // MARK: - Helpers

    private func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
