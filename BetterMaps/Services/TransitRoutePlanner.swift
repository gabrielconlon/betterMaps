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

    private let raptorEngine = RaptorEngine()

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

        // --- RAPTOR-based routing ---
        // Build RAPTOR data structures (cached after first call per session)
        await raptorEngine.buildIfNeeded(
            db: GTFSScheduleService.shared.database,
            activeServices: activeServices,
            allStops: transitStops
        )

        // Map origin/dest stops to (stopId, walkSeconds) pairs
        let originPairs: [(stopId: String, walkSeconds: Int)] = originStopIds.compactMap { id in
            guard let stop = stopById[id] else { return nil }
            return (id, walkingMinutes(from: source, to: stop.coordinate) * 60)
        }
        let destPairs: [(stopId: String, walkSeconds: Int)] = destStopIds.compactMap { id in
            guard let stop = stopById[id] else { return nil }
            return (id, walkingMinutes(from: stop.coordinate, to: destination) * 60)
        }

        let searchStart = Date()
        let journeys = await raptorEngine.search(
            originStops: originPairs,
            destStops: destPairs,
            departureTime: secondsSinceMidnight,
            maxRounds: maxTransfers + 1
        )
        let searchMs = Int(Date().timeIntervalSince(searchStart) * 1000)

        // Convert RAPTOR journeys to TransitRouteOption
        var options: [TransitRouteOption] = []
        for journey in journeys {
            let option = convertJourney(journey, source: source, destination: destination,
                                        departureDate: departureTime, stopById: stopById)
            options.append(option)
            await onRouteFound?(option)
        }

        // --- Best-per-mode selection with preference boost ---
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

        var seen = Set<String>()
        let unique = options.filter { seen.insert("\($0.summary)|\($0.transfers)").inserted }

        var bestByMode: [TransitLegMode: TransitRouteOption] = [:]
        for option in unique {
            guard let mode = option.primaryMode else { continue }
            if let existing = bestByMode[mode] {
                if sortScore(option) < sortScore(existing) { bestByMode[mode] = option }
            } else {
                bestByMode[mode] = option
            }
        }

        var results = Array(bestByMode.values).sorted { sortScore($0) < sortScore($1) }
        let selectedIds = Set(results.map { $0.id })
        let remaining = unique.filter { !selectedIds.contains($0.id) }
            .sorted { sortScore($0) < sortScore($1) }
        for option in remaining where results.count < maxResults {
            results.append(option)
        }

        await APILogger.shared.log(
            service: "Transit Planner", endpoint: "findRoutes",
            status: results.isEmpty ? .failure : .success, durationMs: searchMs,
            detail: "\(results.count) route(s) | \(journeys.count) RAPTOR journeys | \(originStopIds.count) origins, \(destStopIds.count) dests"
        )

        return results
    }

    // MARK: - RAPTOR Journey → TransitRouteOption Conversion

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
