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
    private(set) var debugLog: String = ""

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

        // Fast distance approximation for Dublin (~53°N).
        // Avoids CLLocation object creation + Haversine per stop.
        // At 53°N: 1° lat ≈ 111,320m, 1° lon ≈ cos(53°) * 111,320 ≈ 67,000m
        let latScale = 111_320.0
        let lonScale = 67_000.0

        func fastDistMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
            let dLat = (lat1 - lat2) * latScale
            let dLon = (lon1 - lon2) * lonScale
            return sqrt(dLat * dLat + dLon * dLon)
        }

        // Bounding box pre-filter (degrees) to skip distant stops entirely
        let latMargin = walkRadiusMeters / latScale
        let lonMargin = walkRadiusMeters / lonScale

        // Pre-compute distances from source and destination to all stops
        var srcDist: [Int: Double] = [:]  // stopIndex → meters from source
        var dstDist: [Int: Double] = [:]  // stopIndex → meters from destination

        for (_, idx) in graph.stopIdToIndex {
            let lat = Double(graph.stopLats[idx])
            let lon = Double(graph.stopLons[idx])

            // Quick bounding box check before computing distance
            if abs(lat - source.latitude) <= latMargin && abs(lon - source.longitude) <= lonMargin {
                let dist = fastDistMeters(lat1: lat, lon1: lon, lat2: source.latitude, lon2: source.longitude)
                if dist <= walkRadiusMeters { srcDist[idx] = dist }
            }
            if abs(lat - destination.latitude) <= latMargin && abs(lon - destination.longitude) <= lonMargin {
                let dist = fastDistMeters(lat1: lat, lon1: lon, lat2: destination.latitude, lon2: destination.longitude)
                if dist <= walkRadiusMeters { dstDist[idx] = dist }
            }
        }

        // Diagnostic: log graph composition and nearby stop counts
        let graphRouteTypes = Dictionary(grouping: graph.routes, by: { $0.routeType })
        let typeLabels = graphRouteTypes.map { type, routes in
            let label = type == 0 ? "luas" : type == 2 ? "rail" : type == 3 ? "bus" : "type\(type)"
            return "\(routes.count) \(label)"
        }.sorted().joined(separator: ", ")
        // Track non-bus route failures for diagnostics
        var nonBusDiag: [(name: String, type: Int, reason: String)] = []

        debugLog = "graph: \(graph.routes.count) routes [\(typeLabels)] | \(srcDist.count) near origin, \(dstDist.count) near dest"

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

            // Track non-bus route match results
            if route.routeType != 3 {
                if bestBoard == nil && bestAlight == nil {
                    nonBusDiag.append((route.routeName, route.routeType, "no stops near origin or dest"))
                } else if bestBoard == nil {
                    nonBusDiag.append((route.routeName, route.routeType, "no stop near origin"))
                } else if bestAlight == nil {
                    nonBusDiag.append((route.routeName, route.routeType, "no stop near dest"))
                }
                // "wrong direction" is no longer a failure — we handle both directions
            }

            guard let board = bestBoard, let alight = bestAlight else { continue }

            // Tram/rail lines run both directions with ~symmetric travel times.
            // Use min/max positions so backward travel works (e.g., Green Luas southbound).
            let startPos = min(board.pos, alight.pos)
            let endPos = max(board.pos, alight.pos)
            guard startPos < cumulative.count, endPos < cumulative.count else { continue }

            let rideSec = Int(cumulative[endPos]) - Int(cumulative[startPos])
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

        // Append non-bus route match summary
        let nonBusMatched = journeys.filter { $0.primaryMode != .bus }
        let matchedSummary = Dictionary(grouping: nonBusMatched, by: { $0.primaryMode.rawValue })
            .map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        let failSummary = Dictionary(grouping: nonBusDiag, by: { $0.reason.prefix(while: { $0 != " " && $0 != "(" }) })
            .map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        if !matchedSummary.isEmpty { debugLog += " | matched: \(matchedSummary)" }
        if !failSummary.isEmpty { debugLog += " | unmatched: \(failSummary)" }

        // --- Phase 2: Transfer routes (ride A → walk → ride B) ---
        // Search Luas (routeType 0) FIRST, then rail (routeType 2).
        // Per-route cap ensures every non-bus line gets checked.
        var transferCount = 0
        if maxTransfers > 0 {
            // Luas first (routeType 0 < 2), so Luas→DART transfers are found
            // before Commuter→Bus fills the cap
            let nonBusGraphRoutes = graph.routes
                .filter { $0.routeType == 0 || $0.routeType == 2 }
                .sorted { $0.routeType < $1.routeType }

            // Pre-sort route B candidates: non-bus first so DART/Rail found before bus fills cap
            let sortedRoutesB = graph.routes.sorted { a, b in
                let aIsRail = a.routeType == 0 || a.routeType == 2
                let bIsRail = b.routeType == 0 || b.routeType == 2
                if aIsRail != bIsRail { return aIsRail }
                return false
            }

            for routeA in nonBusGraphRoutes {
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

                // For each stop on route A, check if it's a transfer point.
                // No per-route cap — we need to reach Connolly (mid-line) for Luas→DART.
                for (posA, stopIdA) in routeA.stopIds.enumerated() where posA != bA.pos {
                    guard let transferIdx = graph.stopIdToIndex[stopIdA],
                          posA < cumA.count else { continue }
                    let transferLat = Double(graph.stopLats[transferIdx])
                    let transferLon = Double(graph.stopLons[transferIdx])
                    var busTransfersAtThisStop = 0

                    // Check non-bus routes first as route B so Luas→DART/Rail
                    // connections are found before bus fills the per-route cap
                    for routeB in sortedRoutesB {
                        // Skip same route (any direction) — Red→Red is nonsensical
                        if routeB.routeId == routeA.routeId { continue }

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
                            let dist = fastDistMeters(lat1: transferLat, lon1: transferLon, lat2: bLat, lon2: bLon)
                            if dist <= 400 {
                                let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                                if boardB == nil || walkSec < boardB!.walkSec {
                                    boardB = (bIdx, posB, max(walkSec, 120))  // min 2 min transfer
                                }
                            }
                        }
                        guard let bB = boardB else { continue }

                        // Find alighting on route B near destination (bidirectional)
                        var alightB: (idx: Int, pos: Int, walkSec: Int)?
                        for (posB, stopIdB) in routeB.stopIds.enumerated() where posB != bB.pos {
                            guard let aIdx = graph.stopIdToIndex[stopIdB], let dist = dstDist[aIdx] else { continue }
                            let walkSec = Int(dist * 1.4 / 80.0 * 60.0)
                            if alightB == nil || walkSec < alightB!.walkSec { alightB = (aIdx, posB, walkSec) }
                        }
                        guard let aB = alightB, bB.pos < cumB.count, aB.pos < cumB.count,
                              bA.pos < cumA.count else { continue }

                        let rideA = abs(Int(cumA[posA]) - Int(cumA[bA.pos]))
                        let rideB = abs(Int(cumB[aB.pos]) - Int(cumB[bB.pos]))
                        let totalSec = bA.walkSec + (headwayA / 2) + rideA + bB.walkSec + (headwayB / 2) + rideB + aB.walkSec

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
                        transferCount += 1
                        if routeB.routeType == 3 { busTransfersAtThisStop += 1 }

                        // Cap bus transfers per stop (1 is enough), but always check rail/dart
                        if routeB.routeType == 3 && busTransfersAtThisStop >= 1 { break }
                    }
                    // No per-stop break for the outer loop — keep checking all stops on route A
                }
                if transferCount >= 20 { break }  // Hard safety cap across all routes
            }
        }
        debugLog += " | \(transferCount) transfers"

        // --- Filter infeasible journeys ---
        // Drop routes with unreasonably long walks (>30 min to board stop).
        // The realistic departure times already account for walk time in the display,
        // so this is just a sanity cap — not headway-based, which was too aggressive
        // for Luas/rail stops that are intentionally spaced farther apart.
        journeys = journeys.filter { $0.originWalkSeconds <= 1800 }

        // --- Select best per route (not just per mode) ---
        // Groups by mode + route name so Red Luas and Green Luas are separate slots.
        // Also ensures at least one non-bus option if any exists.
        journeys.sort { $0.totalSeconds < $1.totalSeconds }

        // Dedup key includes all leg route names so Red→DART and Red→rail are separate
        func routeKey(_ j: HeadwayJourney) -> String {
            let mode = j.primaryMode.rawValue
            let names = j.rideLegs.map { $0.routeName }.joined(separator: "→")
            return "\(mode)-\(names)"
        }

        var bestByRoute: [String: HeadwayJourney] = [:]
        for j in journeys {
            let key = routeKey(j)
            if bestByRoute[key] == nil {
                bestByRoute[key] = j
            }
        }

        // Categorize routes for selection priority:
        // 1. Direct non-bus (Red, Green, DART, rail)
        // 2. Fully non-bus transfers (Red→DART, Green→rail)
        // 3. Mixed transfers (Red→bus) — still valuable but lower priority
        // 4. Direct bus
        let allByRoute = Array(bestByRoute.values)

        func priority(_ j: HeadwayJourney) -> Int {
            let allLegsNonBus = j.rideLegs.allSatisfy { $0.routeType == 0 || $0.routeType == 2 }
            if j.transfers == 0 && j.primaryMode != .bus { return 0 }  // Direct Luas/DART/Rail
            if j.transfers > 0 && allLegsNonBus { return 1 }           // Luas→DART, Luas→Rail
            if j.transfers > 0 && j.primaryMode != .bus { return 2 }   // Luas→Bus
            return 3                                                     // Direct bus
        }

        var results = allByRoute.sorted { a, b in
            let pa = priority(a)
            let pb = priority(b)
            if pa != pb { return pa < pb }
            return a.totalSeconds < b.totalSeconds
        }

        return Array(results.prefix(8))
    }
}
