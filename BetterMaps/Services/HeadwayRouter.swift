import Foundation
import CoreLocation

// MARK: - Headway Journey Result

struct HeadwayJourney: Sendable {
    struct Leg: Sendable {
        let routeName: String
        let routeType: Int   // 0=luas, 2=rail, 3=bus
        let boardStopIndex: Int
        let alightStopIndex: Int
        let travelSeconds: Int
        let waitSeconds: Int  // headway/2 estimate
    }

    struct WalkLeg: Sendable {
        let fromStopIndex: Int
        let toStopIndex: Int
        let walkSeconds: Int
    }

    let rideLegs: [Leg]
    let walkLegs: [WalkLeg]
    let originWalkSeconds: Int
    let destWalkSeconds: Int
    let totalSeconds: Int
    let isEstimate: Bool = true

    var transfers: Int { max(0, rideLegs.count - 1) }

    var primaryMode: TransitLegMode {
        guard let first = rideLegs.first else { return .bus }
        switch first.routeType {
        case 0: return .luas
        case 2: return first.routeName.uppercased() == "DART" ? .dart : .rail
        default: return .bus
        }
    }
}

// MARK: - Headway Router (Simple Route Matching)

/// Instant transit route planning by matching routes that serve both origin and destination areas.
/// No graph search needed — just iterate pre-computed routes and check stop proximity.
/// Completes in <10ms for Dublin's ~500 routes.
actor HeadwayRouter {

    private(set) var graph: TransitGraph?

    func loadGraph() {
        graph = TransitGraphBuilder.loadCached()
    }

    func setGraph(_ g: TransitGraph) {
        graph = g
    }

    var isReady: Bool { graph != nil }
    var stalenessLabel: String { graph?.stalenessLabel ?? "No data" }

    /// Find routes that connect origin to destination.
    /// Simple approach: for each route, check if it has stops near both endpoints.
    /// For transfers: check if alighting stop of route A is near boarding stop of route B.
    func search(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        allStops: [TransitStop],
        departureTime: Int,
        maxTransfers: Int = 2,
        walkRadiusMeters: Double = 2500
    ) -> [HeadwayJourney] {
        guard let graph else { return [] }

        let timeBucket = TransitGraph.timeBucket(for: departureTime)
        let srcLoc = CLLocation(latitude: source.latitude, longitude: source.longitude)
        let dstLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)

        // Pre-compute distances from source and destination to all stops
        // Only compute for stops that appear in routes (use graph.stopIdToIndex)
        var srcDist: [Int: Double] = [:]  // stopIndex → meters from source
        var dstDist: [Int: Double] = [:]  // stopIndex → meters from destination

        for (stopId, idx) in graph.stopIdToIndex {
            let lat = Double(graph.stopLats[idx])
            let lon = Double(graph.stopLons[idx])
            let stopLoc = CLLocation(latitude: lat, longitude: lon)

            let fromSrc = stopLoc.distance(from: srcLoc)
            if fromSrc <= walkRadiusMeters { srcDist[idx] = fromSrc }

            let fromDst = stopLoc.distance(from: dstLoc)
            if fromDst <= walkRadiusMeters { dstDist[idx] = fromDst }
        }

        var journeys: [HeadwayJourney] = []

        // --- Phase 1: Direct routes (single ride) ---
        for route in graph.routes {
            let bucket = min(timeBucket, route.cumulativeSeconds.count - 1)
            guard bucket >= 0 else { continue }
            let cumulative = route.cumulativeSeconds[bucket]
            let headway = Int(route.headways[min(bucket, route.headways.count - 1)])

            // Find best boarding stop (closest to source, on this route)
            var bestBoard: (idx: Int, pos: Int, walkSec: Int)?
            // Find best alighting stop (closest to destination, on this route)
            var bestAlight: (idx: Int, pos: Int, walkSec: Int)?

            for (pos, stopId) in route.stopIds.enumerated() {
                guard let stopIdx = graph.stopIdToIndex[stopId] else { continue }

                if let dist = srcDist[stopIdx] {
                    let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                    if bestBoard == nil || walkSec < bestBoard!.walkSec {
                        bestBoard = (stopIdx, pos, walkSec)
                    }
                }

                if let dist = dstDist[stopIdx] {
                    let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                    if bestAlight == nil || walkSec < bestAlight!.walkSec {
                        bestAlight = (stopIdx, pos, walkSec)
                    }
                }
            }

            // Valid if board comes before alight in stop sequence
            guard let board = bestBoard, let alight = bestAlight,
                  board.pos < alight.pos,
                  board.pos < cumulative.count, alight.pos < cumulative.count else { continue }

            let rideSec = Int(cumulative[alight.pos]) - Int(cumulative[board.pos])
            let waitSec = headway / 2
            let totalSec = board.walkSec + waitSec + rideSec + alight.walkSec

            journeys.append(HeadwayJourney(
                rideLegs: [HeadwayJourney.Leg(
                    routeName: route.routeName,
                    routeType: route.routeType,
                    boardStopIndex: board.idx,
                    alightStopIndex: alight.idx,
                    travelSeconds: rideSec,
                    waitSeconds: waitSec
                )],
                walkLegs: [],
                originWalkSeconds: board.walkSec,
                destWalkSeconds: alight.walkSec,
                totalSeconds: totalSec
            ))
        }

        // --- Phase 2: Transfer routes (ride A → walk → ride B) ---
        if maxTransfers > 0 {
            // Prioritize tram/rail as route A so Luas→DART transfers are found
            // before bus→bus fills the cap
            let sortedRoutes = graph.routes.sorted { a, b in
                let aIsRail = a.routeType == 0 || a.routeType == 2
                let bIsRail = b.routeType == 0 || b.routeType == 2
                if aIsRail != bIsRail { return aIsRail }
                return false
            }
            for routeA in sortedRoutes {
                let bucketA = min(timeBucket, routeA.cumulativeSeconds.count - 1)
                guard bucketA >= 0 else { continue }
                let cumA = routeA.cumulativeSeconds[bucketA]
                let headwayA = Int(routeA.headways[min(bucketA, routeA.headways.count - 1)])

                // Find boarding stop on route A near source
                var boardA: (idx: Int, pos: Int, walkSec: Int)?
                for (pos, stopId) in routeA.stopIds.enumerated() {
                    guard let stopIdx = graph.stopIdToIndex[stopId], let dist = srcDist[stopIdx] else { continue }
                    let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                    if boardA == nil || walkSec < boardA!.walkSec { boardA = (stopIdx, pos, walkSec) }
                }
                guard let bA = boardA else { continue }

                // For each stop on route A after boarding, check if it's a transfer point
                for (posA, stopIdA) in routeA.stopIds.enumerated() where posA > bA.pos {
                    guard let transferIdx = graph.stopIdToIndex[stopIdA],
                          posA < cumA.count else { continue }
                    let transferLat = Double(graph.stopLats[transferIdx])
                    let transferLon = Double(graph.stopLons[transferIdx])
                    let transferLoc = CLLocation(latitude: transferLat, longitude: transferLon)

                    // Check routes near this transfer point (rail/tram first)
                    for routeB in sortedRoutes {
                        if routeB.routeId == routeA.routeId && routeB.directionId == routeA.directionId { continue }

                        let bucketB = min(timeBucket, routeB.cumulativeSeconds.count - 1)
                        guard bucketB >= 0 else { continue }
                        let cumB = routeB.cumulativeSeconds[bucketB]
                        let headwayB = Int(routeB.headways[min(bucketB, routeB.headways.count - 1)])

                        // Find boarding on route B near the transfer point
                        var boardB: (idx: Int, pos: Int, walkSec: Int)?
                        for (posB, stopIdB) in routeB.stopIds.enumerated() {
                            guard let bIdx = graph.stopIdToIndex[stopIdB] else { continue }
                            let bLat = Double(graph.stopLats[bIdx])
                            let bLon = Double(graph.stopLons[bIdx])
                            let dist = transferLoc.distance(from: CLLocation(latitude: bLat, longitude: bLon))
                            if dist <= 400 {
                                let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                                if boardB == nil || walkSec < boardB!.walkSec {
                                    boardB = (bIdx, posB, max(walkSec, 120))  // min 2 min transfer
                                }
                            }
                        }
                        guard let bB = boardB else { continue }

                        // Find alighting on route B near destination
                        var alightB: (idx: Int, pos: Int, walkSec: Int)?
                        for (posB, stopIdB) in routeB.stopIds.enumerated() where posB > bB.pos {
                            guard let aIdx = graph.stopIdToIndex[stopIdB], let dist = dstDist[aIdx] else { continue }
                            let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                            if alightB == nil || walkSec < alightB!.walkSec { alightB = (aIdx, posB, walkSec) }
                        }
                        guard let aB = alightB, bB.pos < cumB.count, aB.pos < cumB.count else { continue }

                        let rideA = Int(cumA[posA]) - Int(cumA[bA.pos])
                        let rideB = Int(cumB[aB.pos]) - Int(cumB[bB.pos])
                        let totalSec = bA.walkSec + (headwayA / 2) + rideA + bB.walkSec + (headwayB / 2) + rideB + aB.walkSec

                        // Only include if competitive (not much worse than best direct)
                        let bestDirect = journeys.min(by: { $0.totalSeconds < $1.totalSeconds })?.totalSeconds ?? Int.max
                        if totalSec > bestDirect + 1200 { continue }  // Skip if >20 min slower

                        journeys.append(HeadwayJourney(
                            rideLegs: [
                                HeadwayJourney.Leg(routeName: routeA.routeName, routeType: routeA.routeType,
                                    boardStopIndex: bA.idx, alightStopIndex: transferIdx,
                                    travelSeconds: rideA, waitSeconds: headwayA / 2),
                                HeadwayJourney.Leg(routeName: routeB.routeName, routeType: routeB.routeType,
                                    boardStopIndex: bB.idx, alightStopIndex: aB.idx,
                                    travelSeconds: rideB, waitSeconds: headwayB / 2)
                            ],
                            walkLegs: [HeadwayJourney.WalkLeg(
                                fromStopIndex: transferIdx, toStopIndex: bB.idx, walkSeconds: bB.walkSec
                            )],
                            originWalkSeconds: bA.walkSec,
                            destWalkSeconds: aB.walkSec,
                            totalSeconds: totalSec
                        ))

                        if journeys.count >= 20 { break }  // Cap total results
                    }
                    if journeys.count >= 20 { break }
                }
                if journeys.count >= 20 { break }
            }
        }

        // --- Select best per route (not just per mode) ---
        // Groups by mode + route name so Red Luas and Green Luas are separate slots.
        // Also ensures at least one non-bus option if any exists.
        journeys.sort { $0.totalSeconds < $1.totalSeconds }

        // Dedup key: mode + primary route name (e.g. "luas-Red", "dart-DART", "bus-39A")
        func routeKey(_ j: HeadwayJourney) -> String {
            let mode = j.primaryMode.rawValue
            let name = j.rideLegs.first?.routeName ?? "unknown"
            let transfers = j.transfers > 0 ? "-transfer" : ""
            return "\(mode)-\(name)\(transfers)"
        }

        var bestByRoute: [String: HeadwayJourney] = [:]
        for j in journeys {
            let key = routeKey(j)
            if bestByRoute[key] == nil {
                bestByRoute[key] = j
            }
        }

        // Start with one per route, sorted by time
        var results = Array(bestByRoute.values).sorted { $0.totalSeconds < $1.totalSeconds }

        // Guarantee at least one non-bus option if any exists
        let hasNonBus = results.contains { $0.primaryMode != .bus }
        if !hasNonBus, let bestNonBus = journeys.first(where: { $0.primaryMode != .bus }) {
            results.insert(bestNonBus, at: 0)
        }

        return Array(results.prefix(5))
    }
}
