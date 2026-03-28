import Foundation
import CoreLocation

// MARK: - Transit Leg Mode

enum TransitLegMode: String, Sendable {
    case bus
    case luas
    case dart
    case rail

    init(stopType: TransitStop.TransitStopType) {
        switch stopType {
        case .bus:      self = .bus
        case .luas:     self = .luas
        case .dart:     self = .dart
        case .rail:     self = .rail
        case .suburban: self = .rail
        }
    }
}

// MARK: - Leg Coordinate (Sendable wrapper for CLLocationCoordinate2D)

struct LegCoordinate: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    init(_ coord: CLLocationCoordinate2D) {
        self.latitude = coord.latitude
        self.longitude = coord.longitude
    }
    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Transit Leg

enum TransitLeg: Identifiable, Sendable {
    case walk(id: UUID, durationMinutes: Int, distance: Double, from: String, to: String,
              fromCoord: LegCoordinate, toCoord: LegCoordinate)
    case ride(id: UUID, routeName: String, routeId: String, boardStop: String,
              alightStop: String, departureTime: String, arrivalTime: String,
              numStops: Int, mode: TransitLegMode,
              boardCoord: LegCoordinate, alightCoord: LegCoordinate, pathCoords: [LegCoordinate])
    case transfer(id: UUID, walkMinutes: Int, fromStop: String, toStop: String,
                  fromCoord: LegCoordinate, toCoord: LegCoordinate)

    var id: UUID {
        switch self {
        case .walk(let id, _, _, _, _, _, _):              return id
        case .ride(let id, _, _, _, _, _, _, _, _, _, _, _): return id
        case .transfer(let id, _, _, _, _, _):             return id
        }
    }
}

// MARK: - Transit Route Option

struct TransitRouteOption: Identifiable, Sendable {
    let id: UUID
    let legs: [TransitLeg]
    let totalDuration: TimeInterval   // seconds
    let totalWalkingMinutes: Int
    let departureTime: Date
    let arrivalTime: Date
    let transfers: Int
    let summary: String               // e.g. "39A -> Luas Green"

    /// The mode of the first ride leg (bus, luas, dart, rail)
    var primaryMode: TransitLegMode? {
        for leg in legs {
            if case .ride(_, _, _, _, _, _, _, _, let mode, _, _, _) = leg { return mode }
        }
        return nil
    }
}

// MARK: - Transit Route Planner

/// Finds multi-modal transit routes (walk -> ride -> [transfer -> ride] -> walk)
/// using GTFS schedule data. Runs off the main actor.
actor TransitRoutePlanner {

    // MARK: - Constants

    private let walkingSpeedMPerMin: Double = 80.0
    private let roadRoutingFactor: Double = 1.4
    /// 20-minute departure window (was 60 min — users don't want options departing far in the future)
    private let departureWindowSeconds: Int = 1200
    /// Max results per search — 5 allows room for best-per-mode diversity
    private let maxResults: Int = 5
    /// 15-minute transfer connection window (was 30 min)
    private let transferConnectionSeconds: Int = 900
    /// Minimum transfer buffer (2 minutes)
    private let transferBufferSeconds: Int = 120

    /// Known Dublin interchange stop name keywords — only check these for transfers
    /// instead of every intermediate stop (kills the O(n⁴) problem)
    private let interchangeKeywords = [
        // Luas/Rail hubs
        "connolly", "heuston", "abbey", "tara", "pearse",
        "busáras", "busaras", "o'connell", "oconnell", "dundrum",
        "stillorgan", "sandyford", "jervis", "stephens", "stephen's",
        "george's dock", "mayor square", "spencer dock", "marlborough",
        "ranelagh", "charlemont", "phibsborough", "broombridge",
        // DART stations (for bus/luas → DART transfers)
        "grand canal", "docklands", "lansdowne", "sandymount",
        "sydney parade", "booterstown", "blackrock", "seapoint",
        "salthill", "monkstown", "dun laoghaire", "dalkey",
        "killiney", "shankill", "bray", "greystones",
        "howth junction", "howth", "raheny", "harmonstown",
        "killester", "clontarf", "malahide", "portmarnock",
        // Red Line Luas
        "smithfield", "museum", "four courts", "fatima", "rialto",
        "james", "belgard", "tallaght", "red cow", "kingswood"
    ]

    // MARK: - Public API

    func findRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transitStops: [TransitStop],
        maxTransfers: Int = 1,
        transitPreference: String = "fastest",
        departureTime: Date = Date(),
        onRouteFound: (@Sendable (TransitRouteOption) async -> Void)? = nil
    ) async -> [TransitRouteOption] {

        // Smart radius by mode — generous for rail/tram (fewer, further apart),
        // tighter for bus (many stops, close together) to keep query count reasonable
        let walkRadiusMeters: Double = 2500  // ~30 min walk, main radius for findNearbyStopIds

        await GTFSScheduleService.shared.loadIfNeeded()

        // Find nearby stops per mode with appropriate limits.
        // Bus stops are dense (~10/km²) so cap at 15. Tram/rail are sparse so keep all within radius.
        let stopById = Dictionary(uniqueKeysWithValues: transitStops.map { ($0.id, $0) })

        func nearbyStopIds(near coord: CLLocationCoordinate2D) -> [String] {
            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let nearby = transitStops
                .map { (stop: $0, dist: CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc)) }
                .filter { $0.dist <= walkRadiusMeters }

            // Keep all tram/rail/dart stops (sparse, important for mode diversity)
            let railStops = nearby.filter { $0.stop.type != .bus }.map { $0.stop.id }
            // Keep closest 15 bus stops (dense, more than enough for routing)
            let busStops = nearby.filter { $0.stop.type == .bus }
                .sorted { $0.dist < $1.dist }
                .prefix(15)
                .map { $0.stop.id }
            return railStops + busStops
        }

        let originStopIds = nearbyStopIds(near: source)
        let destStopIds = nearbyStopIds(near: destination)

        guard !originStopIds.isEmpty, !destStopIds.isEmpty else {
            await APILogger.shared.log(
                service: "Transit Planner", endpoint: "findRoutes", status: .failure,
                durationMs: 0,
                detail: "No stops near origin (\(originStopIds.count)) or dest (\(destStopIds.count))"
            )
            return []
        }

        let destStopIdSet = Set(destStopIds)

        // Use Irish timezone for GTFS time calculations
        var irishCal = Calendar.current
        irishCal.timeZone = TimeZone(identifier: "Europe/Dublin")!
        let components = irishCal.dateComponents([.hour, .minute, .second], from: departureTime)
        let secondsSinceMidnight = (components.hour ?? 0) * 3600
                                 + (components.minute ?? 0) * 60
                                 + (components.second ?? 0)

        // Pre-compute active service IDs once (OTP-style) — avoids calendar JOIN per query
        var activeServices = await GTFSScheduleService.shared.activeServiceIds(for: departureTime)

        // After midnight (before 3 AM), also include previous day's services
        // GTFS encodes post-midnight trips as >24:00 on the previous day
        if secondsSinceMidnight < 10800 {
            let yesterday = irishCal.date(byAdding: .day, value: -1, to: departureTime) ?? departureTime
            let yesterdayServices = await GTFSScheduleService.shared.activeServiceIds(for: yesterday)
            activeServices.formUnion(yesterdayServices)
        }

        guard !activeServices.isEmpty else {
            await APILogger.shared.log(
                service: "Transit Planner", endpoint: "findRoutes", status: .failure,
                durationMs: 0, detail: "No active services for today"
            )
            return []
        }

        var directOptions: [TransitRouteOption] = []   // Phase 1: direct routes
        var transferOptions: [TransitRouteOption] = [] // Phase 2: transfer routes

        var totalDepartures = 0

        // Sort origin stops by walk distance so closer stops are checked first.
        // This ensures we find the nearest Luas/DART stop, not a farther one.
        let sortedOriginIds = originStopIds.sorted { a, b in
            guard let sa = stopById[a], let sb = stopById[b] else { return false }
            return walkingDistance(from: source, to: sa.coordinate) < walkingDistance(from: source, to: sb.coordinate)
        }

        // --- Phase 1: Direct routes (no transfer) ---
        // No walk cutoff — walk time factors into total duration for sorting.
        // No early exit — scan all stops to discover all modes (bus, Luas, DART).
        for originStopId in sortedOriginIds {
            guard let originStop = stopById[originStopId] else { continue }

            let walkToOrigin = walkingMinutes(from: source, to: originStop.coordinate)
            let walkToOriginDistance = walkingDistance(from: source, to: originStop.coordinate)
            let effectiveDepartureSeconds = secondsSinceMidnight + walkToOrigin * 60

            let departures = await GTFSScheduleService.shared.departuresFromStop(
                stopId: originStopId,
                afterSeconds: effectiveDepartureSeconds,
                withinSeconds: departureWindowSeconds,
                activeServices: activeServices
            )
            totalDepartures += departures.count

            for (boardStopTime, trip) in departures {

                // Bulk-load all stops for this trip ONCE, then check destinations in-memory.
                // This replaces per-dest tripReachesStop() calls (N×M queries → N queries).
                let tripStops = await GTFSScheduleService.shared.stopsForTrip(tripId: trip.tripId)

                // Find the best alighting stop — closest to destination by walk time
                let reachableDestStops = destStopIds.compactMap { destId -> (stopTime: GTFSStopTime, stop: TransitStop, walkMin: Int, walkDist: Double)? in
                    guard let alightTime = tripStops.first(where: { $0.stopId == destId && $0.stopSequence > boardStopTime.stopSequence }),
                          let stop = stopById[destId] else { return nil }
                    let walkMin = walkingMinutes(from: stop.coordinate, to: destination)
                    let walkDist = walkingDistance(from: stop.coordinate, to: destination)
                    return (alightTime, stop, walkMin, walkDist)
                }
                guard let best = reachableDestStops.min(by: { $0.walkMin < $1.walkMin }) else { continue }

                let alightStopTime = best.stopTime
                let destStop = best.stop
                let walkFromDest = best.walkMin
                let walkFromDestDistance = best.walkDist

                do {
                    let numStops = alightStopTime.stopSequence - boardStopTime.stopSequence
                    let mode = legMode(for: originStop, trip: trip)

                    // Build path coordinates from the already-loaded trip stops
                    let pathCoords = tripStops
                        .filter { $0.stopSequence >= boardStopTime.stopSequence && $0.stopSequence <= alightStopTime.stopSequence }
                        .sorted { $0.stopSequence < $1.stopSequence }
                        .compactMap { stopById[$0.stopId]?.coordinate }
                        .map { LegCoordinate($0) }

                    var legs: [TransitLeg] = []
                    if walkToOrigin > 0 {
                        legs.append(.walk(
                            id: UUID(), durationMinutes: walkToOrigin, distance: walkToOriginDistance,
                            from: "Current Location", to: originStop.name,
                            fromCoord: LegCoordinate(source), toCoord: LegCoordinate(originStop.coordinate)
                        ))
                    }
                    legs.append(.ride(
                        id: UUID(), routeName: trip.routeShortName, routeId: trip.routeId,
                        boardStop: originStop.name, alightStop: destStop.name,
                        departureTime: boardStopTime.departureTime, arrivalTime: alightStopTime.arrivalTime,
                        numStops: numStops, mode: mode,
                        boardCoord: LegCoordinate(originStop.coordinate),
                        alightCoord: LegCoordinate(destStop.coordinate),
                        pathCoords: pathCoords
                    ))
                    if walkFromDest > 0 {
                        legs.append(.walk(
                            id: UUID(), durationMinutes: walkFromDest, distance: walkFromDestDistance,
                            from: destStop.name, to: "Destination",
                            fromCoord: LegCoordinate(destStop.coordinate), toCoord: LegCoordinate(destination)
                        ))
                    }

                    let waitSeconds = boardStopTime.departureSeconds - effectiveDepartureSeconds
                    let rideSeconds = alightStopTime.arrivalSeconds - boardStopTime.departureSeconds
                    let totalSeconds = Double(walkToOrigin * 60)
                                     + Double(max(waitSeconds, 0))
                                     + Double(max(rideSeconds, 0))
                                     + Double(walkFromDest * 60)

                    let depDate = departureTime.addingTimeInterval(Double(walkToOrigin * 60))
                    let arrDate = depDate.addingTimeInterval(
                        Double(max(waitSeconds, 0) + max(rideSeconds, 0)) + Double(walkFromDest * 60)
                    )

                    let route = TransitRouteOption(
                        id: UUID(), legs: legs, totalDuration: totalSeconds,
                        totalWalkingMinutes: walkToOrigin + walkFromDest,
                        departureTime: depDate, arrivalTime: arrDate,
                        transfers: 0, summary: trip.routeShortName
                    )
                    directOptions.append(route)
                    await onRouteFound?(route)
                } // do
            }
        }

        // --- Phase 2: One-transfer routes (always search, separate pool) ---
        // Process non-bus stops first AND check actual departure route types.
        // Some bus stops near Luas stations are misclassified as .luas but return bus routes.
        // Only the real Luas platform stop_ids return actual Luas departures.
        if maxTransfers > 0 {
            outerTransfer: for originStopId in sortedOriginIds {
                guard let originStop = stopById[originStopId] else { continue }

                let walkToOrigin = walkingMinutes(from: source, to: originStop.coordinate)
                let walkToOriginDistance = walkingDistance(from: source, to: originStop.coordinate)
                let effectiveDepartureSeconds = secondsSinceMidnight + walkToOrigin * 60

                let departures = await GTFSScheduleService.shared.departuresFromStop(
                    stopId: originStopId,
                    afterSeconds: effectiveDepartureSeconds,
                    withinSeconds: departureWindowSeconds,
                    activeServices: activeServices
                )

                for (boardStopTime, trip) in departures {
                    // Only cap when we have enough diversity (at least 1 non-bus transfer)
                    // or hit a generous overall limit
                    let hasNonBusTransfer = transferOptions.contains { $0.primaryMode != .bus }
                    if transferOptions.count >= 5 && hasNonBusTransfer { break outerTransfer }
                    if transferOptions.count >= 20 { break outerTransfer }

                    let tripStops = await GTFSScheduleService.shared.stopsForTrip(tripId: trip.tripId)

                    // Only check known interchange stops as transfer points (not every intermediate stop)
                    let interchangeStops = tripStops.filter { st in
                        st.stopSequence > boardStopTime.stopSequence &&
                        !destStopIdSet.contains(st.stopId) &&
                        isInterchangeStop(stopId: st.stopId, stopById: stopById)
                    }

                    // Log non-bus interchange discoveries
                    if originStop.type != .bus && !interchangeStops.isEmpty {
                        let ixNames = interchangeStops.prefix(5).compactMap { stopById[$0.stopId]?.name }
                        await APILogger.shared.log(
                            service: "Transit Planner", endpoint: "transfer-scan",
                            status: .success, durationMs: 0,
                            detail: "\(originStop.name)→\(trip.routeShortName): \(interchangeStops.count) interchanges [\(ixNames.joined(separator: ", "))]"
                        )
                    }

                    for midStopTime in interchangeStops {
                        // Only cap when we have enough diversity (at least 1 non-bus transfer)
                    // or hit a generous overall limit
                    let hasNonBusTransfer = transferOptions.contains { $0.primaryMode != .bus }
                    if transferOptions.count >= 5 && hasNonBusTransfer { break outerTransfer }
                    if transferOptions.count >= 20 { break outerTransfer }

                        guard let midStop = stopById[midStopTime.stopId] else { continue }

                        let arrivalAtMid = midStopTime.arrivalSeconds

                        // Check departures from this interchange (same stop + nearby within 400m)
                        let nearbyTransferIds = await GTFSScheduleService.shared.findNearbyStopIds(
                            coordinate: midStop.coordinate, radiusMeters: 400.0, allStops: transitStops
                        )

                        for transferStopId in nearbyTransferIds {
                            // Only cap when we have enough diversity (at least 1 non-bus transfer)
                    // or hit a generous overall limit
                    let hasNonBusTransfer = transferOptions.contains { $0.primaryMode != .bus }
                    if transferOptions.count >= 5 && hasNonBusTransfer { break outerTransfer }
                    if transferOptions.count >= 20 { break outerTransfer }

                            let connectingDepartures = await GTFSScheduleService.shared.departuresFromStop(
                                stopId: transferStopId,
                                afterSeconds: arrivalAtMid + transferBufferSeconds,
                                withinSeconds: transferConnectionSeconds,
                                activeServices: activeServices
                            )

                            // Log non-bus connecting departures at interchanges
                            if originStop.type != .bus && !connectingDepartures.isEmpty {
                                let connRoutes = Set(connectingDepartures.map { $0.1.routeShortName }).prefix(3)
                                let transferStopName = stopById[transferStopId]?.name ?? transferStopId
                                await APILogger.shared.log(
                                    service: "Transit Planner", endpoint: "transfer-connect",
                                    status: .success, durationMs: 0,
                                    detail: "at \(midStop.name)→\(transferStopName): \(connectingDepartures.count) deps [\(connRoutes.joined(separator: ","))]"
                                )
                            }

                            for (connBoardTime, connTrip) in connectingDepartures {
                                if connTrip.tripId == trip.tripId { continue }

                                // Bulk-load connecting trip stops once (same N+1 fix as Phase 1)
                                let connTripStops = await GTFSScheduleService.shared.stopsForTrip(tripId: connTrip.tripId)

                                for destStopId in destStopIds {
                                    guard let connAlightTime = connTripStops.first(where: {
                                        $0.stopId == destStopId && $0.stopSequence > connBoardTime.stopSequence
                                    }) else { continue }

                                    guard let destStop = stopById[destStopId],
                                          let transferStop = stopById[transferStopId] else { continue }

                                    let walkFromDest = walkingMinutes(from: destStop.coordinate, to: destination)
                                    let walkFromDestDistance = walkingDistance(from: destStop.coordinate, to: destination)

                                    let transferWalkMin: Int = transferStopId == midStopTime.stopId ? 0
                                        : walkingMinutes(from: midStop.coordinate, to: transferStop.coordinate)

                                    let leg1Stops = midStopTime.stopSequence - boardStopTime.stopSequence
                                    let leg2Stops = connAlightTime.stopSequence - connBoardTime.stopSequence
                                    let mode1 = legMode(for: originStop, trip: trip)
                                    let mode2 = legMode(for: transferStop, trip: connTrip)

                                    // Build path coords from already-loaded trip stops
                                    let pathCoords1 = tripStops
                                        .filter { $0.stopSequence >= boardStopTime.stopSequence && $0.stopSequence <= midStopTime.stopSequence }
                                        .sorted { $0.stopSequence < $1.stopSequence }
                                        .compactMap { stopById[$0.stopId]?.coordinate }
                                        .map { LegCoordinate($0) }
                                    let pathCoords2 = connTripStops
                                        .filter { $0.stopSequence >= connBoardTime.stopSequence && $0.stopSequence <= connAlightTime.stopSequence }
                                        .sorted { $0.stopSequence < $1.stopSequence }
                                        .compactMap { stopById[$0.stopId]?.coordinate }
                                        .map { LegCoordinate($0) }

                                    var legs: [TransitLeg] = []
                                    if walkToOrigin > 0 {
                                        legs.append(.walk(
                                            id: UUID(), durationMinutes: walkToOrigin, distance: walkToOriginDistance,
                                            from: "Current Location", to: originStop.name,
                                            fromCoord: LegCoordinate(source), toCoord: LegCoordinate(originStop.coordinate)
                                        ))
                                    }
                                    legs.append(.ride(
                                        id: UUID(), routeName: trip.routeShortName, routeId: trip.routeId,
                                        boardStop: originStop.name, alightStop: midStop.name,
                                        departureTime: boardStopTime.departureTime, arrivalTime: midStopTime.arrivalTime,
                                        numStops: leg1Stops, mode: mode1,
                                        boardCoord: LegCoordinate(originStop.coordinate),
                                        alightCoord: LegCoordinate(midStop.coordinate),
                                        pathCoords: pathCoords1
                                    ))
                                    legs.append(.transfer(
                                        id: UUID(), walkMinutes: max(transferWalkMin, 2),
                                        fromStop: midStop.name, toStop: transferStop.name,
                                        fromCoord: LegCoordinate(midStop.coordinate),
                                        toCoord: LegCoordinate(transferStop.coordinate)
                                    ))
                                    legs.append(.ride(
                                        id: UUID(), routeName: connTrip.routeShortName, routeId: connTrip.routeId,
                                        boardStop: transferStop.name, alightStop: destStop.name,
                                        departureTime: connBoardTime.departureTime, arrivalTime: connAlightTime.arrivalTime,
                                        numStops: leg2Stops, mode: mode2,
                                        boardCoord: LegCoordinate(transferStop.coordinate),
                                        alightCoord: LegCoordinate(destStop.coordinate),
                                        pathCoords: pathCoords2
                                    ))
                                    if walkFromDest > 0 {
                                        legs.append(.walk(
                                            id: UUID(), durationMinutes: walkFromDest, distance: walkFromDestDistance,
                                            from: destStop.name, to: "Destination",
                                            fromCoord: LegCoordinate(destStop.coordinate), toCoord: LegCoordinate(destination)
                                        ))
                                    }

                                    let waitSeconds1 = boardStopTime.departureSeconds - effectiveDepartureSeconds
                                    let ride1Seconds = midStopTime.arrivalSeconds - boardStopTime.departureSeconds
                                    let transferWaitSeconds = connBoardTime.departureSeconds - midStopTime.arrivalSeconds
                                    let ride2Seconds = connAlightTime.arrivalSeconds - connBoardTime.departureSeconds

                                    let totalSeconds = Double(walkToOrigin * 60)
                                                     + Double(max(waitSeconds1, 0))
                                                     + Double(max(ride1Seconds, 0))
                                                     + Double(max(transferWaitSeconds, 0))
                                                     + Double(max(ride2Seconds, 0))
                                                     + Double(walkFromDest * 60)

                                    let depDate = departureTime.addingTimeInterval(Double(walkToOrigin * 60))
                                    let arrDate = depDate.addingTimeInterval(totalSeconds - Double(walkToOrigin * 60))

                                    let route = TransitRouteOption(
                                        id: UUID(), legs: legs, totalDuration: totalSeconds,
                                        totalWalkingMinutes: walkToOrigin + transferWalkMin + walkFromDest,
                                        departureTime: depDate, arrivalTime: arrDate,
                                        transfers: 1, summary: "\(trip.routeShortName) → \(connTrip.routeShortName)"
                                    )
                                    transferOptions.append(route)
                                    await onRouteFound?(route)
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- Best-per-mode selection ---
        // Guarantees mode diversity: one result per mode (bus, luas, dart, rail),
        // then fill remaining slots with next-best options.

        // Sort score with mode preference boost
        let sortScore: (TransitRouteOption) -> Double = { option in
            let base = option.totalDuration
            guard let mode = option.primaryMode else { return base }
            switch transitPreference {
            case "preferTramRail":
                return (mode == .luas || mode == .dart || mode == .rail) ? base - 600 : base
            case "preferBus":
                return mode == .bus ? base - 600 : base
            default:
                return base
            }
        }

        // Merge direct + transfer results and deduplicate
        let allOptions = directOptions + transferOptions
        var seen = Set<String>()
        let unique = allOptions.filter { option in
            let key = "\(option.summary)|\(option.transfers)"
            return seen.insert(key).inserted
        }

        // Pick best per mode
        var bestByMode: [TransitLegMode: TransitRouteOption] = [:]
        for option in unique {
            guard let mode = option.primaryMode else { continue }
            if let existing = bestByMode[mode] {
                if sortScore(option) < sortScore(existing) { bestByMode[mode] = option }
            } else {
                bestByMode[mode] = option
            }
        }

        // Start with one per mode, sorted by preference
        var results = Array(bestByMode.values).sorted { sortScore($0) < sortScore($1) }

        // Fill remaining slots with next-best overall
        let selectedIds = Set(results.map { $0.id })
        let remaining = unique.filter { !selectedIds.contains($0.id) }
            .sorted { sortScore($0) < sortScore($1) }
        for option in remaining where results.count < maxResults {
            results.append(option)
        }

        await APILogger.shared.log(
            service: "Transit Planner", endpoint: "findRoutes",
            status: results.isEmpty ? .failure : .success, durationMs: 0,
            detail: "\(results.count) route(s) | \(originStopIds.count) origins, \(destStopIds.count) dests | \(totalDepartures) deps | \(directOptions.count) direct + \(transferOptions.count) transfers found"
        )

        return results
    }

    // MARK: - Helpers

    /// Build an array of coordinates for all stops on a trip between two sequences (inclusive).
    /// Used to draw multi-segment polylines on the map that follow the actual route path.
    private func buildPathCoords(
        tripId: String,
        fromSequence: Int,
        toSequence: Int,
        stopById: [String: TransitStop]
    ) async -> [LegCoordinate] {
        let tripStops = await GTFSScheduleService.shared.stopsForTrip(tripId: tripId)
        return tripStops
            .filter { $0.stopSequence >= fromSequence && $0.stopSequence <= toSequence }
            .sorted { $0.stopSequence < $1.stopSequence }
            .compactMap { stopById[$0.stopId]?.coordinate }
            .map { LegCoordinate($0) }
    }

    /// Check if a stop is a known interchange (by name keyword match).
    func isInterchangeStop(stopId: String, stopById: [String: TransitStop]) -> Bool {
        guard let stop = stopById[stopId] else { return false }
        let lowercaseName = stop.name.lowercased()
        return interchangeKeywords.contains { lowercaseName.contains($0) }
    }

    func walkingMinutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Int {
        let distance = walkingDistance(from: from, to: to)
        return Int(ceil(distance / walkingSpeedMPerMin))
    }

    func walkingDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let locB = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return locA.distance(from: locB) * roadRoutingFactor
    }

    func legMode(for stop: TransitStop, trip: GTFSTrip) -> TransitLegMode {
        // Use GTFS route_type + route_short_name for accurate mode detection.
        // All Irish Rail services share route_type=2, so we check the route name
        // to distinguish DART from Commuter/InterCity.
        switch trip.routeType {
        case 0: return .luas   // Tram/Light Rail = Luas
        case 2: return trip.routeShortName.uppercased() == "DART" ? .dart : .rail
        case 3: return .bus
        default: return TransitLegMode(stopType: stop.type)
        }
    }
}
