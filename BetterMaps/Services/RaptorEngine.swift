import Foundation
import CoreLocation
import SQLite3

// MARK: - RAPTOR Journey Result

struct RaptorJourney: Sendable {
    struct Leg: Sendable {
        let boardStopId: String
        let alightStopId: String
        let tripId: String
        let routeId: String
        let routeType: Int        // 0=tram, 2=rail, 3=bus
        let routeShortName: String
        let boardTime: Int         // seconds since midnight
        let alightTime: Int
    }

    struct WalkLeg: Sendable {
        let fromStopId: String
        let toStopId: String
        let walkSeconds: Int
    }

    let legs: [Leg]
    let walkLegs: [WalkLeg]        // transfer walks between legs
    let originWalkSeconds: Int     // walk from user to first board stop
    let destWalkSeconds: Int       // walk from last alight stop to destination
    let departureTime: Int         // seconds since midnight
    let arrivalTime: Int
    var totalSeconds: Int { arrivalTime - departureTime + originWalkSeconds }
    var transfers: Int { max(0, legs.count - 1) }
}

// MARK: - RAPTOR Engine

/// Round-Based Public Transit Routing (RAPTOR) algorithm.
/// Pre-computes data structures from GTFS SQLite for near-instant (~50-200ms) route queries.
/// Discovers ALL optimal multi-modal connections without hardcoded interchange lists.
actor RaptorEngine {

    // MARK: - Pre-computed Data Structures

    /// Route patterns: route_id → ordered [stop_id] (deduplicated from trips)
    private var routeStops: [[String]] = []
    /// Route metadata: parallel to routeStops
    private var routeInfo: [(routeId: String, routeType: Int, routeName: String)] = []
    /// Stop → indices into routeStops for routes serving this stop
    private var stopRoutes: [String: [Int]] = [:]
    /// Stop → sorted departures [(departureSeconds, tripIndex, stopPositionInRoute)]
    private var stopDepartures: [String: [(dep: Int, tripIdx: Int, pos: Int)]] = [:]
    /// Trip schedules: tripIndex → [(stopId, arrivalSec, departureSec)]
    private var tripSchedules: [[(stopId: String, arr: Int, dep: Int)]] = []
    /// Trip route index: tripIndex → routeIndex
    private var tripRouteIndex: [Int] = []
    /// Transfer footpaths: stop_id → [(toStopId, walkSeconds)]
    private var transfers: [String: [(stop: String, walk: Int)]] = [:]
    /// Stop coordinates for walk time calculations
    private var stopCoords: [String: (lat: Double, lon: Double)] = [:]

    private var isBuilt = false
    var isReady: Bool { isBuilt }

    // MARK: - Build Data Structures

    /// Build all RAPTOR data structures from GTFS SQLite. Called once per session.
    func buildIfNeeded(db: GTFSDatabase, activeServices: Set<String>, allStops: [TransitStop]) {
        guard !isBuilt else { return }
        let start = Date()

        // 1. Load stop coordinates
        for stop in allStops {
            stopCoords[stop.id] = (stop.latitude, stop.longitude)
        }

        // 2. Load all trips for active services, grouped by route
        var routeTrips: [String: [(tripId: String, stops: [(stopId: String, arr: Int, dep: Int)])]] = [:]
        var routeMeta: [String: (routeType: Int, routeName: String)] = [:]

        // Query all stop_times for active service trips
        let serviceList = activeServices.joined(separator: "','")
        let sql = """
            SELECT st.trip_id, st.stop_id, st.arrival_seconds, st.departure_seconds, st.stop_sequence,
                   t.route_id, r.route_type, COALESCE(r.route_short_name, t.route_short_name, '')
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            LEFT JOIN routes r ON t.route_id = r.route_id
            WHERE t.service_id IN ('\(serviceList)')
            ORDER BY st.trip_id, st.stop_sequence
        """

        var currentTripId = ""
        var currentRouteId = ""
        var currentStops: [(stopId: String, arr: Int, dep: Int)] = []

        if let stmt = db.prepare(sql) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tripId = db.columnText(stmt, index: 0) ?? ""
                let stopId = db.columnText(stmt, index: 1) ?? ""
                let arr = db.columnInt(stmt, index: 2)
                let dep = db.columnInt(stmt, index: 3)
                let routeId = db.columnText(stmt, index: 5) ?? ""
                let routeType = db.columnInt(stmt, index: 6)
                let routeName = db.columnText(stmt, index: 7) ?? ""

                if tripId != currentTripId {
                    // Save previous trip
                    if !currentTripId.isEmpty && !currentStops.isEmpty {
                        routeTrips[currentRouteId, default: []].append((currentTripId, currentStops))
                    }
                    currentTripId = tripId
                    currentRouteId = routeId
                    currentStops = []
                    if routeMeta[routeId] == nil {
                        routeMeta[routeId] = (routeType, routeName)
                    }
                }
                currentStops.append((stopId, arr, dep))
            }
            // Save last trip
            if !currentTripId.isEmpty && !currentStops.isEmpty {
                routeTrips[currentRouteId, default: []].append((currentTripId, currentStops))
            }
            db.finalize(stmt)
        }

        // 3. Build route patterns and trip schedules
        var routeIdx = 0
        for (routeId, trips) in routeTrips {
            guard let firstTrip = trips.first else { continue }
            let pattern = firstTrip.stops.map { $0.stopId }
            let meta = routeMeta[routeId] ?? (3, "")

            routeStops.append(pattern)
            routeInfo.append((routeId, meta.routeType, meta.routeName))

            // Index stops → route
            for (pos, stopId) in pattern.enumerated() {
                stopRoutes[stopId, default: []].append(routeIdx)
            }

            // Store each trip's schedule
            for trip in trips {
                let tripIdx = tripSchedules.count
                tripSchedules.append(trip.stops)
                tripRouteIndex.append(routeIdx)

                // Index departures per stop
                for (pos, st) in trip.stops.enumerated() {
                    stopDepartures[st.stopId, default: []].append((st.dep, tripIdx, pos))
                }
            }

            routeIdx += 1
        }

        // Sort departures by time at each stop
        for (stopId, deps) in stopDepartures {
            stopDepartures[stopId] = deps.sorted { $0.dep < $1.dep }
        }

        // 4. Build transfer footpaths (walking connections between stops within 300m)
        buildTransfers(allStops: allStops, maxMeters: 300)

        isBuilt = true

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Task {
            await APILogger.shared.log(
                service: "RAPTOR", endpoint: "build",
                status: .success, durationMs: ms,
                detail: "\(routeStops.count) routes, \(tripSchedules.count) trips, \(stopDepartures.count) stops with deps, \(transfers.count) stops with transfers"
            )
        }
    }

    /// Build walking transfer connections using grid-based spatial index
    private func buildTransfers(allStops: [TransitStop], maxMeters: Double) {
        // Grid-based spatial index to avoid O(n²)
        let gridSize = 0.003  // ~300m in degrees
        var grid: [String: [TransitStop]] = [:]
        for stop in allStops {
            let key = "\(Int(stop.latitude / gridSize)),\(Int(stop.longitude / gridSize))"
            grid[key, default: []].append(stop)
        }

        let walkingSpeed = 80.0  // meters per minute
        let roadFactor = 1.4

        for stop in allStops {
            let gridX = Int(stop.latitude / gridSize)
            let gridY = Int(stop.longitude / gridSize)
            var nearby: [(stop: String, walk: Int)] = []

            // Check neighboring grid cells
            for dx in -1...1 {
                for dy in -1...1 {
                    let key = "\(gridX + dx),\(gridY + dy)"
                    guard let cell = grid[key] else { continue }
                    for other in cell where other.id != stop.id {
                        let dist = haversine(lat1: stop.latitude, lon1: stop.longitude,
                                           lat2: other.latitude, lon2: other.longitude)
                        if dist <= maxMeters {
                            let walkSec = Int((dist * roadFactor / walkingSpeed) * 60)
                            nearby.append((other.id, walkSec))
                        }
                    }
                }
            }

            if !nearby.isEmpty {
                transfers[stop.id] = nearby
            }
        }
    }

    // MARK: - RAPTOR Search

    /// Core RAPTOR search. Returns Pareto-optimal journeys (minimizing arrival time AND transfers).
    func search(
        originStops: [(stopId: String, walkSeconds: Int)],
        destStops: [(stopId: String, walkSeconds: Int)],
        departureTime: Int,
        maxRounds: Int = 3
    ) -> [RaptorJourney] {

        let numStops = stopDepartures.count
        guard numStops > 0 else { return [] }

        // τ[stop] = earliest known arrival time at stop
        var tau: [String: Int] = [:]
        // τ*[stop] = earliest known arrival from previous round (for Pareto dominance)
        var tauStar: [String: Int] = [:]
        // Parent pointers for journey reconstruction: stop → (round, boardStop, tripIdx, boardTime)
        var parent: [String: [(round: Int, boardStop: String, tripIdx: Int, boardTime: Int, alightTime: Int)]] = [:]
        // Transfer parent: stop → (round, fromStop, walkSeconds)
        var transferParent: [String: (round: Int, fromStop: String, walkSec: Int)] = [:]
        // Marked stops (improved in current round)
        var marked = Set<String>()

        // Initialize: walk from origin to nearby stops
        for (stopId, walkSec) in originStops {
            let arrTime = departureTime + walkSec
            tau[stopId] = arrTime
            tauStar[stopId] = arrTime
            marked.insert(stopId)
        }

        // Also propagate through initial transfers
        for (stopId, _) in originStops {
            guard let nearby = transfers[stopId] else { continue }
            for (toStop, walkSec) in nearby {
                let arrTime = (tau[stopId] ?? Int.max) + walkSec
                if arrTime < (tau[toStop] ?? Int.max) {
                    tau[toStop] = arrTime
                    tauStar[toStop] = arrTime
                    marked.insert(toStop)
                }
            }
        }

        // Best known arrival at any destination stop (for early termination)
        var bestDestArrival = Int.max
        for (stopId, walkSec) in destStops {
            if let t = tau[stopId] {
                bestDestArrival = min(bestDestArrival, t + walkSec)
            }
        }

        // Journeys found per round (for Pareto-optimal selection)
        var journeysByRound: [Int: Int] = [:]  // round → best arrival time at dest

        // Rounds
        for round in 1...maxRounds {
            var newMarked = Set<String>()

            // Collect routes serving any marked stop
            var routesToScan = Set<Int>()
            for stopId in marked {
                if let routes = stopRoutes[stopId] {
                    for routeIdx in routes {
                        routesToScan.insert(routeIdx)
                    }
                }
            }

            // Scan each route
            for routeIdx in routesToScan {
                let pattern = routeStops[routeIdx]
                var boardedTrip: Int? = nil
                var boardedAt: Int = -1
                var boardTime: Int = 0

                for (pos, stopId) in pattern.enumerated() {
                    // Can we improve arrival at this stop using the boarded trip?
                    if let tripIdx = boardedTrip {
                        let schedule = tripSchedules[tripIdx]
                        if pos < schedule.count {
                            let arrTime = schedule[pos].arr
                            if arrTime > 0 && arrTime < (tau[stopId] ?? Int.max) && arrTime < bestDestArrival {
                                tau[stopId] = arrTime
                                newMarked.insert(stopId)
                                // Record parent for reconstruction
                                let boardStopId = pattern[boardedAt]
                                parent[stopId, default: []].append((round, boardStopId, tripIdx, boardTime, arrTime))
                            }
                        }
                    }

                    // Can we board an earlier trip at this stop?
                    if marked.contains(stopId) || newMarked.contains(stopId) {
                        let earliest = tau[stopId] ?? Int.max
                        if let deps = stopDepartures[stopId] {
                            // Binary search for first departure >= earliest
                            let idx = binarySearch(deps, target: earliest)
                            if idx < deps.count {
                                let candidate = deps[idx]
                                // Only board if this trip serves this route pattern
                                if tripRouteIndex[candidate.tripIdx] == routeIdx {
                                    if boardedTrip == nil || candidate.dep < boardTime {
                                        boardedTrip = candidate.tripIdx
                                        boardedAt = pos
                                        boardTime = candidate.dep
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Process transfers (walking between nearby stops)
            let stopsToTransfer = newMarked
            for stopId in stopsToTransfer {
                guard let nearby = transfers[stopId] else { continue }
                let arrAtStop = tau[stopId] ?? Int.max
                for (toStop, walkSec) in nearby {
                    let arrViaTransfer = arrAtStop + walkSec
                    if arrViaTransfer < (tau[toStop] ?? Int.max) && arrViaTransfer < bestDestArrival {
                        tau[toStop] = arrViaTransfer
                        newMarked.insert(toStop)
                        transferParent[toStop] = (round, stopId, walkSec)
                    }
                }
            }

            // Check destination stops
            for (stopId, walkSec) in destStops {
                if let t = tau[stopId] {
                    let totalArr = t + walkSec
                    if totalArr < bestDestArrival {
                        bestDestArrival = totalArr
                        journeysByRound[round] = totalArr
                    }
                }
            }

            marked = newMarked
            if marked.isEmpty { break }  // No improvements — done
        }

        // Reconstruct journeys
        return reconstructJourneys(
            destStops: destStops, originStops: originStops,
            parent: parent, transferParent: transferParent,
            departureTime: departureTime, bestDestArrival: bestDestArrival
        )
    }

    // MARK: - Journey Reconstruction

    private func reconstructJourneys(
        destStops: [(stopId: String, walkSeconds: Int)],
        originStops: [(stopId: String, walkSeconds: Int)],
        parent: [String: [(round: Int, boardStop: String, tripIdx: Int, boardTime: Int, alightTime: Int)]],
        transferParent: [String: (round: Int, fromStop: String, walkSec: Int)],
        departureTime: Int,
        bestDestArrival: Int
    ) -> [RaptorJourney] {

        var journeys: [RaptorJourney] = []
        let originSet = Set(originStops.map { $0.stopId })
        let originWalkMap = Dictionary(uniqueKeysWithValues: originStops.map { ($0.stopId, $0.walkSeconds) })

        for (destStopId, destWalkSec) in destStops {
            guard parent[destStopId] != nil || originSet.contains(destStopId) else { continue }

            // Trace back from destination
            var legs: [RaptorJourney.Leg] = []
            var walkLegs: [RaptorJourney.WalkLeg] = []
            var currentStop = destStopId

            // Follow parent pointers backward
            while let parents = parent[currentStop], let p = parents.last {
                let rIdx = tripRouteIndex[p.tripIdx]
                let info = routeInfo[rIdx]

                legs.insert(RaptorJourney.Leg(
                    boardStopId: p.boardStop,
                    alightStopId: currentStop,
                    tripId: "trip_\(p.tripIdx)",
                    routeId: info.routeId,
                    routeType: info.routeType,
                    routeShortName: info.routeName,
                    boardTime: p.boardTime,
                    alightTime: p.alightTime
                ), at: 0)

                // Check if there was a transfer walk to the board stop
                if let tp = transferParent[p.boardStop] {
                    walkLegs.insert(RaptorJourney.WalkLeg(
                        fromStopId: tp.fromStop, toStopId: p.boardStop, walkSeconds: tp.walkSec
                    ), at: 0)
                    currentStop = tp.fromStop
                } else {
                    currentStop = p.boardStop
                }

                // Reached an origin stop?
                if originSet.contains(currentStop) { break }
            }

            guard !legs.isEmpty else { continue }

            let originWalk = originWalkMap[currentStop] ?? 0
            let firstBoardTime = legs.first?.boardTime ?? departureTime
            let lastAlightTime = legs.last?.alightTime ?? departureTime
            let arrivalTime = lastAlightTime + destWalkSec

            let journey = RaptorJourney(
                legs: legs,
                walkLegs: walkLegs,
                originWalkSeconds: originWalk,
                destWalkSeconds: destWalkSec,
                departureTime: firstBoardTime - originWalk,
                arrivalTime: arrivalTime
            )
            journeys.append(journey)
        }

        // Deduplicate and return Pareto-optimal (by arrival time + transfers)
        journeys.sort { a, b in
            if a.transfers != b.transfers { return a.transfers < b.transfers }
            return a.arrivalTime < b.arrivalTime
        }

        // Keep Pareto front: a journey is dominated if another has both fewer transfers AND earlier arrival
        var paretoFront: [RaptorJourney] = []
        for j in journeys {
            let dominated = paretoFront.contains { $0.transfers <= j.transfers && $0.arrivalTime <= j.arrivalTime }
            if !dominated {
                paretoFront.append(j)
            }
        }

        return paretoFront
    }

    // MARK: - Helpers

    /// Binary search for first element with dep >= target
    private func binarySearch(_ arr: [(dep: Int, tripIdx: Int, pos: Int)], target: Int) -> Int {
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].dep < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Haversine distance in meters
    private func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Reset for new service day
    func invalidate() {
        isBuilt = false
        routeStops = []
        routeInfo = []
        stopRoutes = [:]
        stopDepartures = [:]
        tripSchedules = []
        tripRouteIndex = []
        transfers = [:]
        stopCoords = [:]
    }
}
