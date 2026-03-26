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

// MARK: - Transit Leg

enum TransitLeg: Identifiable, Sendable {
    case walk(id: UUID, durationMinutes: Int, distance: Double, from: String, to: String)
    case ride(id: UUID, routeName: String, routeId: String, boardStop: String,
              alightStop: String, departureTime: String, arrivalTime: String,
              numStops: Int, mode: TransitLegMode)
    case transfer(id: UUID, walkMinutes: Int, fromStop: String, toStop: String)

    var id: UUID {
        switch self {
        case .walk(let id, _, _, _, _):           return id
        case .ride(let id, _, _, _, _, _, _, _, _): return id
        case .transfer(let id, _, _, _):          return id
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

    /// Average walking speed in meters per minute.
    private let walkingSpeedMPerMin: Double = 80.0
    /// Road-routing factor applied to straight-line distance.
    private let roadRoutingFactor: Double = 1.4
    /// Default walking radius when no profile is provided (15 min * 80 m/min).
    private let defaultMaxWalkingMinutes: Int = 15
    /// Default max transfers when no profile is provided.
    private let defaultMaxTransfers: Int = 2
    /// Time window (seconds) to search for departures from a stop.
    private let departureWindowSeconds: Int = 3600
    /// Maximum number of route options to return.
    private let maxResults: Int = 5

    // MARK: - Public API

    /// Find multi-modal transit route options between two coordinates.
    ///
    /// - Parameters:
    ///   - source: Origin coordinate.
    ///   - destination: Destination coordinate.
    ///   - transitStops: All known transit stops (from GTFSStopLoader).
    ///   - profile: Optional user preferences (walk budget, transfer limit, bus vs tram).
    ///   - departureTime: Requested departure time (defaults to now).
    /// - Returns: Up to 5 route options sorted by total duration.
    func findRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transitStops: [TransitStop],
        profile: UserProfile?,
        departureTime: Date = Date()
    ) async -> [TransitRouteOption] {

        let maxWalkMin = profile?.maxWalkingMinutes ?? defaultMaxWalkingMinutes
        let maxTransfers = profile?.maxTransfers ?? defaultMaxTransfers
        let preferBus = profile?.preferBusOverTram ?? false

        let walkRadiusMeters = Double(maxWalkMin) * walkingSpeedMPerMin

        // Ensure schedule data is loaded.
        await GTFSScheduleService.shared.loadIfNeeded()

        // Step 1: Find stops near origin and destination.
        let originStopIds = await GTFSScheduleService.shared.findNearbyStopIds(
            coordinate: source, radiusMeters: walkRadiusMeters, allStops: transitStops
        )
        let destStopIds = await GTFSScheduleService.shared.findNearbyStopIds(
            coordinate: destination, radiusMeters: walkRadiusMeters, allStops: transitStops
        )

        guard !originStopIds.isEmpty, !destStopIds.isEmpty else {
            return []
        }

        // Build quick-lookup structures.
        let stopById = Dictionary(uniqueKeysWithValues: transitStops.map { ($0.id, $0) })
        let destStopIdSet = Set(destStopIds)

        // Step 2: Seconds since midnight for the departure time.
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second], from: departureTime)
        let secondsSinceMidnight = (components.hour ?? 0) * 3600
                                 + (components.minute ?? 0) * 60
                                 + (components.second ?? 0)

        // Step 3: Collect candidate route options.
        var options: [TransitRouteOption] = []

        for originStopId in originStopIds {
            guard let originStop = stopById[originStopId] else { continue }

            // Walk time from source to this origin stop.
            let walkToOrigin = walkingMinutes(from: source, to: originStop.coordinate)
            if walkToOrigin > maxWalkMin { continue }

            let walkToOriginDistance = walkingDistance(from: source, to: originStop.coordinate)

            // Adjust departure seconds to account for walk to the stop.
            let effectiveDepartureSeconds = secondsSinceMidnight + walkToOrigin * 60

            // Step 4: Get departures from this origin stop.
            let departures = await GTFSScheduleService.shared.departuresFromStop(
                stopId: originStopId,
                afterSeconds: effectiveDepartureSeconds,
                withinSeconds: departureWindowSeconds
            )

            for (boardStopTime, trip) in departures {

                // Step 5: Check direct routes first.
                for destStopId in destStopIds {
                    if let alightStopTime = await GTFSScheduleService.shared.tripReachesStop(
                        tripId: trip.tripId,
                        stopId: destStopId,
                        afterSequence: boardStopTime.stopSequence
                    ) {
                        guard let destStop = stopById[destStopId] else { continue }

                        let walkFromDest = walkingMinutes(
                            from: destStop.coordinate, to: destination
                        )
                        if walkFromDest > maxWalkMin { continue }

                        let walkFromDestDistance = walkingDistance(
                            from: destStop.coordinate, to: destination
                        )

                        // Count intermediate stops.
                        let numStops = alightStopTime.stopSequence - boardStopTime.stopSequence

                        let mode = legMode(for: originStop, trip: trip)

                        // Build legs.
                        var legs: [TransitLeg] = []
                        if walkToOrigin > 0 {
                            legs.append(.walk(
                                id: UUID(),
                                durationMinutes: walkToOrigin,
                                distance: walkToOriginDistance,
                                from: "Current Location",
                                to: originStop.name
                            ))
                        }
                        legs.append(.ride(
                            id: UUID(),
                            routeName: trip.routeShortName,
                            routeId: trip.routeId,
                            boardStop: originStop.name,
                            alightStop: destStop.name,
                            departureTime: boardStopTime.departureTime,
                            arrivalTime: alightStopTime.arrivalTime,
                            numStops: numStops,
                            mode: mode
                        ))
                        if walkFromDest > 0 {
                            legs.append(.walk(
                                id: UUID(),
                                durationMinutes: walkFromDest,
                                distance: walkFromDestDistance,
                                from: destStop.name,
                                to: "Destination"
                            ))
                        }

                        let waitSeconds = boardStopTime.departureSeconds - effectiveDepartureSeconds
                        let rideSeconds = alightStopTime.arrivalSeconds - boardStopTime.departureSeconds
                        let totalSeconds = Double(walkToOrigin * 60)
                                         + Double(max(waitSeconds, 0))
                                         + Double(max(rideSeconds, 0))
                                         + Double(walkFromDest * 60)

                        let depDate = departureTime.addingTimeInterval(
                            Double(walkToOrigin * 60)
                        )
                        let arrDate = depDate.addingTimeInterval(
                            Double(max(waitSeconds, 0) + max(rideSeconds, 0))
                                + Double(walkFromDest * 60)
                        )

                        options.append(TransitRouteOption(
                            id: UUID(),
                            legs: legs,
                            totalDuration: totalSeconds,
                            totalWalkingMinutes: walkToOrigin + walkFromDest,
                            departureTime: depDate,
                            arrivalTime: arrDate,
                            transfers: 0,
                            summary: trip.routeShortName
                        ))
                    }
                }

                // Step 6: One-transfer routes (if allowed).
                guard maxTransfers > 0 else { continue }

                let tripStops = await GTFSScheduleService.shared.stopsForTrip(tripId: trip.tripId)
                let boardIdx = boardStopTime.stopSequence

                // Look at every intermediate stop as a potential transfer point.
                for intermediateStopTime in tripStops where intermediateStopTime.stopSequence > boardIdx {
                    let midStopId = intermediateStopTime.stopId
                    // Skip if this is already a destination stop (handled above).
                    if destStopIdSet.contains(midStopId) { continue }

                    guard let midStop = stopById[midStopId] else { continue }

                    // Allow a short transfer walk — find nearby stops within ~400m.
                    let transferRadiusMeters: Double = 400.0
                    let nearbyTransferIds = await GTFSScheduleService.shared.findNearbyStopIds(
                        coordinate: midStop.coordinate,
                        radiusMeters: transferRadiusMeters,
                        allStops: transitStops
                    )

                    // Time we arrive at the intermediate stop.
                    let arrivalAtMid = intermediateStopTime.arrivalSeconds
                    // Allow 2 min minimum transfer time.
                    let transferBuffer = 120

                    for transferStopId in nearbyTransferIds {
                        // Avoid transferring back to the same route at same stop.
                        if transferStopId == midStopId
                            && nearbyTransferIds.count > 1 { /* allow same-stop transfer */ }

                        let connectingDepartures = await GTFSScheduleService.shared.departuresFromStop(
                            stopId: transferStopId,
                            afterSeconds: arrivalAtMid + transferBuffer,
                            withinSeconds: 1800 // 30 min window for connection
                        )

                        for (connBoardTime, connTrip) in connectingDepartures {
                            // Skip same trip.
                            if connTrip.tripId == trip.tripId { continue }

                            // Check if connecting trip reaches any destination stop.
                            for destStopId in destStopIds {
                                guard let connAlightTime = await GTFSScheduleService.shared.tripReachesStop(
                                    tripId: connTrip.tripId,
                                    stopId: destStopId,
                                    afterSequence: connBoardTime.stopSequence
                                ) else { continue }

                                guard let destStop = stopById[destStopId],
                                      let transferStop = stopById[transferStopId] else { continue }

                                let walkFromDest = walkingMinutes(
                                    from: destStop.coordinate, to: destination
                                )
                                if walkFromDest > maxWalkMin { continue }

                                let walkFromDestDistance = walkingDistance(
                                    from: destStop.coordinate, to: destination
                                )

                                // Transfer walk time between intermediate stop and connecting stop.
                                let transferWalkMin: Int
                                if transferStopId == midStopId {
                                    transferWalkMin = 0
                                } else {
                                    transferWalkMin = walkingMinutes(
                                        from: midStop.coordinate,
                                        to: transferStop.coordinate
                                    )
                                }

                                let totalWalkMin = walkToOrigin + transferWalkMin + walkFromDest

                                let leg1Stops = intermediateStopTime.stopSequence - boardStopTime.stopSequence
                                let leg2Stops = connAlightTime.stopSequence - connBoardTime.stopSequence
                                let mode1 = legMode(for: originStop, trip: trip)
                                let mode2 = legMode(for: transferStop, trip: connTrip)

                                // Build legs.
                                var legs: [TransitLeg] = []
                                if walkToOrigin > 0 {
                                    legs.append(.walk(
                                        id: UUID(),
                                        durationMinutes: walkToOrigin,
                                        distance: walkToOriginDistance,
                                        from: "Current Location",
                                        to: originStop.name
                                    ))
                                }
                                legs.append(.ride(
                                    id: UUID(),
                                    routeName: trip.routeShortName,
                                    routeId: trip.routeId,
                                    boardStop: originStop.name,
                                    alightStop: midStop.name,
                                    departureTime: boardStopTime.departureTime,
                                    arrivalTime: intermediateStopTime.arrivalTime,
                                    numStops: leg1Stops,
                                    mode: mode1
                                ))
                                legs.append(.transfer(
                                    id: UUID(),
                                    walkMinutes: max(transferWalkMin, 2),
                                    fromStop: midStop.name,
                                    toStop: transferStop.name
                                ))
                                legs.append(.ride(
                                    id: UUID(),
                                    routeName: connTrip.routeShortName,
                                    routeId: connTrip.routeId,
                                    boardStop: transferStop.name,
                                    alightStop: destStop.name,
                                    departureTime: connBoardTime.departureTime,
                                    arrivalTime: connAlightTime.arrivalTime,
                                    numStops: leg2Stops,
                                    mode: mode2
                                ))
                                if walkFromDest > 0 {
                                    legs.append(.walk(
                                        id: UUID(),
                                        durationMinutes: walkFromDest,
                                        distance: walkFromDestDistance,
                                        from: destStop.name,
                                        to: "Destination"
                                    ))
                                }

                                // Timing.
                                let waitSeconds1 = boardStopTime.departureSeconds - effectiveDepartureSeconds
                                let ride1Seconds = intermediateStopTime.arrivalSeconds - boardStopTime.departureSeconds
                                let transferWaitSeconds = connBoardTime.departureSeconds - intermediateStopTime.arrivalSeconds
                                let ride2Seconds = connAlightTime.arrivalSeconds - connBoardTime.departureSeconds

                                let totalSeconds = Double(walkToOrigin * 60)
                                                 + Double(max(waitSeconds1, 0))
                                                 + Double(max(ride1Seconds, 0))
                                                 + Double(max(transferWaitSeconds, 0))
                                                 + Double(max(ride2Seconds, 0))
                                                 + Double(walkFromDest * 60)

                                let depDate = departureTime.addingTimeInterval(
                                    Double(walkToOrigin * 60)
                                )
                                let arrDate = depDate.addingTimeInterval(
                                    totalSeconds - Double(walkToOrigin * 60)
                                )

                                let summary = "\(trip.routeShortName) -> \(connTrip.routeShortName)"

                                options.append(TransitRouteOption(
                                    id: UUID(),
                                    legs: legs,
                                    totalDuration: totalSeconds,
                                    totalWalkingMinutes: totalWalkMin,
                                    departureTime: depDate,
                                    arrivalTime: arrDate,
                                    transfers: 1,
                                    summary: summary
                                ))
                            }
                        }
                    }
                }
            }
        }

        // Step 7: Sort and deduplicate.
        var sorted = options.sorted { lhs, rhs in
            if preferBus {
                let lhsHasBus = lhs.legs.contains { if case .ride(_, _, _, _, _, _, _, _, .bus) = $0 { true } else { false } }
                let rhsHasBus = rhs.legs.contains { if case .ride(_, _, _, _, _, _, _, _, .bus) = $0 { true } else { false } }
                if lhsHasBus != rhsHasBus { return lhsHasBus }
            }
            return lhs.totalDuration < rhs.totalDuration
        }

        // Deduplicate by summary + transfer count (keep earliest).
        var seen = Set<String>()
        sorted = sorted.filter { option in
            let key = "\(option.summary)|\(option.transfers)"
            return seen.insert(key).inserted
        }

        let results = Array(sorted.prefix(maxResults))

        // Step 8: Log result.
        await APILogger.shared.log(
            service: "Transit Planner",
            endpoint: "findRoutes",
            status: results.isEmpty ? .failure : .success,
            durationMs: 0,
            detail: "\(results.count) route(s) found from \(originStopIds.count) origin stop(s), \(destStopIds.count) dest stop(s)"
        )

        return results
    }

    // MARK: - Helpers

    /// Estimate walking time in minutes between two coordinates,
    /// using straight-line distance * road routing factor / walking speed.
    private func walkingMinutes(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Int {
        let distance = walkingDistance(from: from, to: to)
        return Int(ceil(distance / walkingSpeedMPerMin))
    }

    /// Estimate walking distance in meters (straight-line * road routing factor).
    private func walkingDistance(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        let locA = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let locB = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return locA.distance(from: locB) * roadRoutingFactor
    }

    /// Determine the transit leg mode from the stop type and trip route ID.
    private func legMode(for stop: TransitStop, trip: GTFSTrip) -> TransitLegMode {
        // Use stop type as primary signal.
        switch stop.type {
        case .luas: return .luas
        case .dart: return .dart
        case .rail, .suburban: return .rail
        case .bus: return .bus
        }
    }

    /// Convert HH:MM:SS string to seconds since midnight (mirrors GTFSStopTime).
    private func timeStringToSeconds(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
