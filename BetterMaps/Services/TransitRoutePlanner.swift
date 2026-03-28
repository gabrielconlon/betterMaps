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
    static let shared = TransitRoutePlanner()

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

    private let raptorEngine = RaptorEngine()
    let headwayRouter = HeadwayRouter()

    /// Expose RAPTOR engine for pre-building at app startup
    func getRaptorEngine() -> RaptorEngine { raptorEngine }

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

        await GTFSScheduleService.shared.loadIfNeeded()

        // HeadwayRouter handles its own distance filtering using the transit graph.
        // We just need the stop lookup dictionary for converting results back to UI.
        let stopById = Dictionary(uniqueKeysWithValues: transitStops.map { ($0.id, $0) })

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

        // --- Layer 1: HeadwayRouter (instant, ~5ms) ---
        // Uses pre-computed travel times + headway estimates for instant results
        let searchStart = Date()
        var options: [TransitRouteOption] = []

        if await headwayRouter.isReady {
            let headwayJourneys = await headwayRouter.search(
                from: source, to: destination,
                allStops: transitStops,
                departureTime: secondsSinceMidnight,
                maxTransfers: maxTransfers
            )

            let currentGraph = await headwayRouter.graph
            for journey in headwayJourneys {
                let option = convertHeadwayJourney(journey, source: source, destination: destination,
                                                    departureDate: departureTime, graph: currentGraph, stopById: stopById)
                options.append(option)
                await onRouteFound?(option)
            }

            let headwayMs = Int(Date().timeIntervalSince(searchStart) * 1000)
            let graphDebug = await headwayRouter.debugLog
            await APILogger.shared.log(
                service: "HeadwayRouter", endpoint: "search",
                status: options.isEmpty ? .failure : .success, durationMs: headwayMs,
                detail: "\(options.count) routes in \(headwayMs)ms | \(graphDebug) | \(await headwayRouter.stalenessLabel)"
            )
        }

        // Return HeadwayRouter results directly — RoutingViewModel handles
        // mode diversity, favorites, and preference-based scoring.
        // Previously a second best-per-mode filter here was killing non-bus results.

        // Log with mode breakdown so we can diagnose "all bus" issues
        let modeBreakdown = Dictionary(grouping: options, by: { $0.primaryMode?.rawValue ?? "?" })
            .map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        let totalMs = Int(Date().timeIntervalSince(searchStart) * 1000)
        await APILogger.shared.log(
            service: "Transit Planner", endpoint: "findRoutes",
            status: options.isEmpty ? .failure : .success, durationMs: totalMs,
            detail: "\(options.count) route(s) [\(modeBreakdown)]"
        )

        return options
    }

    // MARK: - RAPTOR Journey → TransitRouteOption Conversion

    private func convertHeadwayJourney(
        _ journey: HeadwayJourney,
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        departureDate: Date,
        graph: TransitGraph?,
        stopById: [String: TransitStop]
    ) -> TransitRouteOption {
        var transitLegs: [TransitLeg] = []

        // Walk to first board stop
        if journey.originWalkSeconds > 0, let first = journey.rideLegs.first {
            let stopId = graph?.stopIds[first.boardStopIndex] ?? ""
            let stop = stopById[stopId]
            transitLegs.append(.walk(
                id: UUID(), durationMinutes: journey.originWalkSeconds / 60,
                distance: Double(journey.originWalkSeconds) / 60 * walkingSpeedMPerMin,
                from: "Current Location", to: stop?.name ?? "Stop",
                fromCoord: LegCoordinate(source),
                toCoord: LegCoordinate(stop?.coordinate ?? source)
            ))
        }

        for (i, leg) in journey.rideLegs.enumerated() {
            let boardId = graph?.stopIds[leg.boardStopIndex] ?? ""
            let alightId = graph?.stopIds[leg.alightStopIndex] ?? ""
            let boardStop = stopById[boardId]
            let alightStop = stopById[alightId]

            let mode: TransitLegMode = {
                switch leg.routeType {
                case 0: return .luas
                case 2: return leg.routeName.uppercased() == "DART" ? .dart : .rail
                default: return .bus
                }
            }()

            // Transfer walk before this leg (if not first)
            if i > 0 {
                if let wl = journey.walkLegs.first(where: { $0.toStopIndex == leg.boardStopIndex }) {
                    let fromId = graph?.stopIds[wl.fromStopIndex] ?? ""
                    let fromStop = stopById[fromId]
                    transitLegs.append(.transfer(
                        id: UUID(), walkMinutes: max(wl.walkSeconds / 60, 2),
                        fromStop: fromStop?.name ?? "Stop", toStop: boardStop?.name ?? "Stop",
                        fromCoord: LegCoordinate(fromStop?.coordinate ?? source),
                        toCoord: LegCoordinate(boardStop?.coordinate ?? destination)
                    ))
                }
            }

            transitLegs.append(.ride(
                id: UUID(), routeName: leg.routeName, routeId: "",
                boardStop: boardStop?.name ?? boardId,
                alightStop: alightStop?.name ?? alightId,
                departureTime: "~\(leg.waitSeconds / 60) min wait",
                arrivalTime: "~\(leg.travelSeconds / 60) min ride",
                numStops: 0, mode: mode,
                boardCoord: LegCoordinate(boardStop?.coordinate ?? source),
                alightCoord: LegCoordinate(alightStop?.coordinate ?? destination),
                pathCoords: []
            ))
        }

        // Walk from last alight to destination
        if journey.destWalkSeconds > 0, let last = journey.rideLegs.last {
            let stopId = graph?.stopIds[last.alightStopIndex] ?? ""
            let stop = stopById[stopId]
            transitLegs.append(.walk(
                id: UUID(), durationMinutes: journey.destWalkSeconds / 60,
                distance: Double(journey.destWalkSeconds) / 60 * walkingSpeedMPerMin,
                from: stop?.name ?? "Stop", to: "Destination",
                fromCoord: LegCoordinate(stop?.coordinate ?? destination),
                toCoord: LegCoordinate(destination)
            ))
        }

        let summary = journey.rideLegs.map { $0.routeName }.joined(separator: " → ")

        return TransitRouteOption(
            id: UUID(), legs: transitLegs,
            totalDuration: Double(journey.totalSeconds),
            totalWalkingMinutes: (journey.originWalkSeconds + journey.destWalkSeconds) / 60,
            departureTime: departureDate,
            arrivalTime: departureDate.addingTimeInterval(Double(journey.totalSeconds)),
            transfers: journey.transfers,
            summary: summary.isEmpty ? "Transit" : summary
        )
    }

    private func convertJourney(
        _ journey: RaptorJourney,
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        departureDate: Date,
        stopById: [String: TransitStop]
    ) -> TransitRouteOption {
        var transitLegs: [TransitLeg] = []
        let walkLegMap = Dictionary(uniqueKeysWithValues: journey.walkLegs.map { ($0.toStopId, $0) })

        // Initial walk to first board stop
        if journey.originWalkSeconds > 0, let firstLeg = journey.legs.first,
           let boardStop = stopById[firstLeg.boardStopId] {
            transitLegs.append(.walk(
                id: UUID(), durationMinutes: journey.originWalkSeconds / 60,
                distance: Double(journey.originWalkSeconds) / 60 * walkingSpeedMPerMin,
                from: "Current Location", to: boardStop.name,
                fromCoord: LegCoordinate(source), toCoord: LegCoordinate(boardStop.coordinate)
            ))
        }

        for (i, leg) in journey.legs.enumerated() {
            let boardStop = stopById[leg.boardStopId]
            let alightStop = stopById[leg.alightStopId]
            let mode: TransitLegMode = {
                switch leg.routeType {
                case 0: return .luas
                case 2: return leg.routeShortName.uppercased() == "DART" ? .dart : .rail
                default: return .bus
                }
            }()

            // Add transfer walk before this leg (if not the first leg)
            if i > 0, let walkLeg = walkLegMap[leg.boardStopId],
               let fromStop = stopById[walkLeg.fromStopId],
               let toStop = stopById[walkLeg.toStopId] {
                transitLegs.append(.transfer(
                    id: UUID(), walkMinutes: max(walkLeg.walkSeconds / 60, 2),
                    fromStop: fromStop.name, toStop: toStop.name,
                    fromCoord: LegCoordinate(fromStop.coordinate),
                    toCoord: LegCoordinate(toStop.coordinate)
                ))
            }

            // Format times
            let depTimeStr = formatSeconds(leg.boardTime)
            let arrTimeStr = formatSeconds(leg.alightTime)

            transitLegs.append(.ride(
                id: UUID(), routeName: leg.routeShortName, routeId: leg.routeId,
                boardStop: boardStop?.name ?? leg.boardStopId,
                alightStop: alightStop?.name ?? leg.alightStopId,
                departureTime: depTimeStr, arrivalTime: arrTimeStr,
                numStops: 0, mode: mode,
                boardCoord: LegCoordinate(boardStop?.coordinate ?? source),
                alightCoord: LegCoordinate(alightStop?.coordinate ?? destination),
                pathCoords: []  // RAPTOR doesn't produce path coords (use shape data if needed)
            ))
        }

        // Final walk to destination
        if journey.destWalkSeconds > 0, let lastLeg = journey.legs.last,
           let alightStop = stopById[lastLeg.alightStopId] {
            transitLegs.append(.walk(
                id: UUID(), durationMinutes: journey.destWalkSeconds / 60,
                distance: Double(journey.destWalkSeconds) / 60 * walkingSpeedMPerMin,
                from: alightStop.name, to: "Destination",
                fromCoord: LegCoordinate(alightStop.coordinate), toCoord: LegCoordinate(destination)
            ))
        }

        let totalWalkMin = (journey.originWalkSeconds + journey.destWalkSeconds +
                           journey.walkLegs.reduce(0) { $0 + $1.walkSeconds }) / 60

        var irishCal = Calendar(identifier: .gregorian)
        irishCal.timeZone = TimeZone(identifier: "Europe/Dublin")!
        let startOfDay = irishCal.startOfDay(for: departureDate)
        let depDate = startOfDay.addingTimeInterval(Double(journey.departureTime))
        let arrDate = depDate.addingTimeInterval(Double(journey.arrivalTime - journey.departureTime))

        let summary = journey.legs.map { $0.routeShortName }.joined(separator: " → ")

        return TransitRouteOption(
            id: UUID(), legs: transitLegs,
            totalDuration: Double(journey.arrivalTime - journey.departureTime),
            totalWalkingMinutes: totalWalkMin,
            departureTime: depDate, arrivalTime: arrDate,
            transfers: journey.transfers, summary: summary
        )
    }

    private func formatSeconds(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
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
