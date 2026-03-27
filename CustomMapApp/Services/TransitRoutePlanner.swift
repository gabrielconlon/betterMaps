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
    /// Max 3 results (was 5 — users want 1-3 fast options, not a wall of choices)
    private let maxResults: Int = 3
    /// 15-minute transfer connection window (was 30 min)
    private let transferConnectionSeconds: Int = 900
    /// Minimum transfer buffer (2 minutes)
    private let transferBufferSeconds: Int = 120

    /// Known Dublin interchange stop name keywords — only check these for transfers
    /// instead of every intermediate stop (kills the O(n⁴) problem)
    private let interchangeKeywords = [
        "connolly", "heuston", "abbey", "tara", "pearse",
        "busáras", "busaras", "o'connell", "oconnell", "dundrum",
        "stillorgan", "sandyford", "jervis", "stephens", "stephen's",
        "george's dock", "mayor square", "spencer dock", "marlborough",
        "ranelagh", "charlemont", "phibsborough", "broombridge"
    ]

    // MARK: - Public API

    func findRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transitStops: [TransitStop],
        maxWalkingMinutes: Int = 15,
        maxTransfers: Int = 1,
        preferBusOverTram: Bool = false,
        departureTime: Date = Date()
    ) async -> [TransitRouteOption] {

        let maxWalkMin = maxWalkingMinutes
        let preferBus = preferBusOverTram

        let walkRadiusMeters = Double(maxWalkMin) * walkingSpeedMPerMin

        await GTFSScheduleService.shared.loadIfNeeded()

        // Find stops near origin and destination
        let originStopIds = await GTFSScheduleService.shared.findNearbyStopIds(
            coordinate: source, radiusMeters: walkRadiusMeters, allStops: transitStops
        )
        let destStopIds = await GTFSScheduleService.shared.findNearbyStopIds(
            coordinate: destination, radiusMeters: walkRadiusMeters, allStops: transitStops
        )

        guard !originStopIds.isEmpty, !destStopIds.isEmpty else {
            await APILogger.shared.log(
                service: "Transit Planner", endpoint: "findRoutes", status: .failure,
                durationMs: 0,
                detail: "No stops near origin (\(originStopIds.count)) or dest (\(destStopIds.count))"
            )
            return []
        }

        let stopById = Dictionary(uniqueKeysWithValues: transitStops.map { ($0.id, $0) })
        let destStopIdSet = Set(destStopIds)

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second], from: departureTime)
        let secondsSinceMidnight = (components.hour ?? 0) * 3600
                                 + (components.minute ?? 0) * 60
                                 + (components.second ?? 0)

        var options: [TransitRouteOption] = []

        // --- Phase 1: Direct routes (no transfer) ---
        for originStopId in originStopIds {
            guard let originStop = stopById[originStopId] else { continue }

            let walkToOrigin = walkingMinutes(from: source, to: originStop.coordinate)
            if walkToOrigin > maxWalkMin { continue }
            let walkToOriginDistance = walkingDistance(from: source, to: originStop.coordinate)
            let effectiveDepartureSeconds = secondsSinceMidnight + walkToOrigin * 60

            let departures = await GTFSScheduleService.shared.departuresFromStop(
                stopId: originStopId,
                afterSeconds: effectiveDepartureSeconds,
                withinSeconds: departureWindowSeconds
            )

            for (boardStopTime, trip) in departures {
                // Early exit: found enough direct routes
                if options.count >= maxResults { break }

                for destStopId in destStopIds {
                    guard let alightStopTime = await GTFSScheduleService.shared.tripReachesStop(
                        tripId: trip.tripId, stopId: destStopId,
                        afterSequence: boardStopTime.stopSequence
                    ) else { continue }

                    guard let destStop = stopById[destStopId] else { continue }

                    let walkFromDest = walkingMinutes(from: destStop.coordinate, to: destination)
                    if walkFromDest > maxWalkMin { continue }
                    let walkFromDestDistance = walkingDistance(from: destStop.coordinate, to: destination)

                    let numStops = alightStopTime.stopSequence - boardStopTime.stopSequence
                    let mode = legMode(for: originStop, trip: trip)

                    // Build path coordinates through intermediate stops
                    let pathCoords = await buildPathCoords(
                        tripId: trip.tripId,
                        fromSequence: boardStopTime.stopSequence,
                        toSequence: alightStopTime.stopSequence,
                        stopById: stopById
                    )

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

                    options.append(TransitRouteOption(
                        id: UUID(), legs: legs, totalDuration: totalSeconds,
                        totalWalkingMinutes: walkToOrigin + walkFromDest,
                        departureTime: depDate, arrivalTime: arrDate,
                        transfers: 0, summary: trip.routeShortName
                    ))
                }
            }
            if options.count >= maxResults { break }
        }

        // --- Phase 2: One-transfer routes (only if <2 direct routes found) ---
        if options.count < 2 && maxTransfers > 0 {
            outerTransfer: for originStopId in originStopIds {
                guard let originStop = stopById[originStopId] else { continue }

                let walkToOrigin = walkingMinutes(from: source, to: originStop.coordinate)
                if walkToOrigin > maxWalkMin { continue }
                let walkToOriginDistance = walkingDistance(from: source, to: originStop.coordinate)
                let effectiveDepartureSeconds = secondsSinceMidnight + walkToOrigin * 60

                let departures = await GTFSScheduleService.shared.departuresFromStop(
                    stopId: originStopId,
                    afterSeconds: effectiveDepartureSeconds,
                    withinSeconds: departureWindowSeconds
                )

                for (boardStopTime, trip) in departures {
                    if options.count >= maxResults { break outerTransfer }

                    let tripStops = await GTFSScheduleService.shared.stopsForTrip(tripId: trip.tripId)

                    // Only check known interchange stops as transfer points (not every intermediate stop)
                    let interchangeStops = tripStops.filter { st in
                        st.stopSequence > boardStopTime.stopSequence &&
                        !destStopIdSet.contains(st.stopId) &&
                        isInterchangeStop(stopId: st.stopId, stopById: stopById)
                    }

                    for midStopTime in interchangeStops {
                        if options.count >= maxResults { break outerTransfer }

                        guard let midStop = stopById[midStopTime.stopId] else { continue }

                        let arrivalAtMid = midStopTime.arrivalSeconds

                        // Check departures from this interchange (same stop + nearby within 400m)
                        let nearbyTransferIds = await GTFSScheduleService.shared.findNearbyStopIds(
                            coordinate: midStop.coordinate, radiusMeters: 400.0, allStops: transitStops
                        )

                        for transferStopId in nearbyTransferIds {
                            if options.count >= maxResults { break outerTransfer }

                            let connectingDepartures = await GTFSScheduleService.shared.departuresFromStop(
                                stopId: transferStopId,
                                afterSeconds: arrivalAtMid + transferBufferSeconds,
                                withinSeconds: transferConnectionSeconds
                            )

                            for (connBoardTime, connTrip) in connectingDepartures {
                                if connTrip.tripId == trip.tripId { continue }

                                for destStopId in destStopIds {
                                    guard let connAlightTime = await GTFSScheduleService.shared.tripReachesStop(
                                        tripId: connTrip.tripId, stopId: destStopId,
                                        afterSequence: connBoardTime.stopSequence
                                    ) else { continue }

                                    guard let destStop = stopById[destStopId],
                                          let transferStop = stopById[transferStopId] else { continue }

                                    let walkFromDest = walkingMinutes(from: destStop.coordinate, to: destination)
                                    if walkFromDest > maxWalkMin { continue }
                                    let walkFromDestDistance = walkingDistance(from: destStop.coordinate, to: destination)

                                    let transferWalkMin: Int = transferStopId == midStopTime.stopId ? 0
                                        : walkingMinutes(from: midStop.coordinate, to: transferStop.coordinate)

                                    let leg1Stops = midStopTime.stopSequence - boardStopTime.stopSequence
                                    let leg2Stops = connAlightTime.stopSequence - connBoardTime.stopSequence
                                    let mode1 = legMode(for: originStop, trip: trip)
                                    let mode2 = legMode(for: transferStop, trip: connTrip)

                                    let pathCoords1 = await buildPathCoords(
                                        tripId: trip.tripId,
                                        fromSequence: boardStopTime.stopSequence,
                                        toSequence: midStopTime.stopSequence,
                                        stopById: stopById
                                    )
                                    let pathCoords2 = await buildPathCoords(
                                        tripId: connTrip.tripId,
                                        fromSequence: connBoardTime.stopSequence,
                                        toSequence: connAlightTime.stopSequence,
                                        stopById: stopById
                                    )

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

                                    options.append(TransitRouteOption(
                                        id: UUID(), legs: legs, totalDuration: totalSeconds,
                                        totalWalkingMinutes: walkToOrigin + transferWalkMin + walkFromDest,
                                        departureTime: depDate, arrivalTime: arrDate,
                                        transfers: 1, summary: "\(trip.routeShortName) → \(connTrip.routeShortName)"
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- Sort and deduplicate ---
        var sorted = options.sorted { lhs, rhs in
            if preferBus {
                let lhsHasBus = lhs.legs.contains { if case .ride(_, _, _, _, _, _, _, _, .bus, _, _, _) = $0 { true } else { false } }
                let rhsHasBus = rhs.legs.contains { if case .ride(_, _, _, _, _, _, _, _, .bus, _, _, _) = $0 { true } else { false } }
                if lhsHasBus != rhsHasBus { return lhsHasBus }
            }
            return lhs.totalDuration < rhs.totalDuration
        }

        var seen = Set<String>()
        sorted = sorted.filter { option in
            let key = "\(option.summary)|\(option.transfers)"
            return seen.insert(key).inserted
        }

        let results = Array(sorted.prefix(maxResults))

        await APILogger.shared.log(
            service: "Transit Planner", endpoint: "findRoutes",
            status: results.isEmpty ? .failure : .success, durationMs: 0,
            detail: "\(results.count) route(s) from \(originStopIds.count) origin, \(destStopIds.count) dest stops"
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
    private func isInterchangeStop(stopId: String, stopById: [String: TransitStop]) -> Bool {
        guard let stop = stopById[stopId] else { return false }
        let lowercaseName = stop.name.lowercased()
        return interchangeKeywords.contains { lowercaseName.contains($0) }
    }

    private func walkingMinutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Int {
        let distance = walkingDistance(from: from, to: to)
        return Int(ceil(distance / walkingSpeedMPerMin))
    }

    private func walkingDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let locB = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return locA.distance(from: locB) * roadRoutingFactor
    }

    private func legMode(for stop: TransitStop, trip: GTFSTrip) -> TransitLegMode {
        // Use GTFS route_type for accurate mode detection — stop classification
        // can be wrong (e.g. GTFS Luas stop classified as bus), but the route_type
        // from the routes table is authoritative.
        switch trip.routeType {
        case 0: return .luas   // Tram/Light Rail = Luas
        case 2: return stop.type == .dart ? .dart : .rail  // Rail (DART or mainline)
        case 3: return .bus
        default: return TransitLegMode(stopType: stop.type)
        }
    }
}
