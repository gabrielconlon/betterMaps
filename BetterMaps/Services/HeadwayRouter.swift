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
    let walkLegs: [WalkLeg]       // transfer walks between ride legs
    let originWalkSeconds: Int    // walk from user to first board stop
    let destWalkSeconds: Int      // walk from last alight stop to destination
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

// MARK: - Headway Router

/// Instant transit route planning using pre-computed headway graph.
/// Dijkstra search on ~21K edges completes in ~5-10ms.
actor HeadwayRouter {

    private var graph: TransitGraph?

    /// Load cached transit graph
    func loadGraph() {
        graph = TransitGraphBuilder.loadCached()
    }

    /// Set graph directly (after build)
    func setGraph(_ g: TransitGraph) {
        graph = g
    }

    var isReady: Bool { graph != nil }

    var stalenessLabel: String { graph?.stalenessLabel ?? "No data" }

    /// Dijkstra search for multi-modal routes
    func search(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        allStops: [TransitStop],
        departureTime: Int,  // seconds since midnight
        maxTransfers: Int = 2,
        walkRadiusMeters: Double = 2500
    ) -> [HeadwayJourney] {
        guard let graph else { return [] }

        let timeBucket = TransitGraph.timeBucket(for: departureTime)
        let srcLoc = CLLocation(latitude: source.latitude, longitude: source.longitude)
        let dstLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)

        // Find origin stops (walkable from source)
        var originStops: [(index: Int, walkSec: Int)] = []
        for (i, stop) in allStops.enumerated() {
            let dist = CLLocation(latitude: stop.latitude, longitude: stop.longitude).distance(from: srcLoc)
            if dist <= walkRadiusMeters {
                let walkSec = Int(dist * 1.4 / 80 * 60)
                originStops.append((i, walkSec))
            }
        }

        // Find destination stops
        var destStops: [(index: Int, walkSec: Int)] = []
        for (i, stop) in allStops.enumerated() {
            let dist = CLLocation(latitude: stop.latitude, longitude: stop.longitude).distance(from: dstLoc)
            if dist <= walkRadiusMeters {
                let walkSec = Int(dist * 1.4 / 80 * 60)
                destStops.append((i, walkSec))
            }
        }

        guard !originStops.isEmpty, !destStops.isEmpty else { return [] }
        let destSet = Set(destStops.map { $0.index })

        // Build adjacency from graph for this time bucket
        // Edge types: transit (route segment) and walking (transfer)
        struct Edge {
            let to: Int          // stop index
            let weight: Int      // total seconds (travel + wait)
            let routeIdx: Int    // -1 for walking
            let alightIdx: Int   // stop index where we get off (for transit, = to)
        }

        // Pre-build edges per stop from routes
        var adjList: [Int: [Edge]] = [:]

        for (routeIdx, route) in graph.routes.enumerated() {
            let bucket = min(timeBucket, route.cumulativeSeconds.count - 1)
            guard bucket >= 0, bucket < route.cumulativeSeconds.count else { continue }
            let cumulative = route.cumulativeSeconds[bucket]
            let headway = Int(route.headways[min(bucket, route.headways.count - 1)])
            let waitEstimate = headway / 2

            // For each stop on the route, add edge to every subsequent stop
            for i in 0..<route.stopIds.count {
                guard let fromIdx = graph.stopIdToIndex[route.stopIds[i]] else { continue }

                for j in (i + 1)..<route.stopIds.count {
                    guard let toIdx = graph.stopIdToIndex[route.stopIds[j]] else { continue }
                    let travelSec = Int(cumulative[j]) - Int(cumulative[i])
                    let totalWeight = waitEstimate + travelSec

                    adjList[fromIdx, default: []].append(Edge(
                        to: toIdx, weight: totalWeight,
                        routeIdx: routeIdx, alightIdx: toIdx
                    ))
                }
            }
        }

        // Add walking transfer edges
        for transfer in graph.transfers {
            adjList[transfer.fromStopIndex, default: []].append(Edge(
                to: transfer.toStopIndex, weight: Int(transfer.walkSeconds),
                routeIdx: -1, alightIdx: transfer.toStopIndex
            ))
        }

        // Dijkstra with transfer counting
        struct State: Comparable {
            let stopIdx: Int
            let cost: Int
            let transfers: Int
            let parent: Int       // previous stop
            let routeIdx: Int     // route used to get here (-1 = walk)

            static func < (lhs: State, rhs: State) -> Bool {
                lhs.cost < rhs.cost
            }
        }

        // Priority queue (simple sorted array — fast enough for ~21K edges)
        var pq: [State] = []
        var bestCost: [Int: Int] = [:]  // stopIdx → best known cost
        var parentMap: [Int: State] = [:]  // stopIdx → state that reached it

        // Initialize with origin stops
        for (idx, walkSec) in originStops {
            let state = State(stopIdx: idx, cost: walkSec, transfers: 0, parent: -1, routeIdx: -1)
            pq.append(state)
            bestCost[idx] = walkSec
        }
        pq.sort()

        // Track best arrivals at destination stops
        var bestDestArrivals: [(destIdx: Int, cost: Int, state: State)] = []

        while !pq.isEmpty {
            let current = pq.removeFirst()

            // Skip if we've found a better path to this stop
            if current.cost > (bestCost[current.stopIdx] ?? Int.max) { continue }
            if current.transfers > maxTransfers { continue }

            parentMap[current.stopIdx] = current

            // Check if this is a destination stop
            if destSet.contains(current.stopIdx) {
                if let destInfo = destStops.first(where: { $0.index == current.stopIdx }) {
                    let totalCost = current.cost + destInfo.walkSec
                    bestDestArrivals.append((current.stopIdx, totalCost, current))
                }
            }

            // Explore edges
            guard let edges = adjList[current.stopIdx] else { continue }
            for edge in edges {
                let isTransfer = current.routeIdx != -1 && edge.routeIdx != -1 && edge.routeIdx != current.routeIdx
                let newTransfers = current.transfers + (isTransfer ? 1 : 0)
                if newTransfers > maxTransfers { continue }

                let newCost = current.cost + edge.weight
                if newCost < (bestCost[edge.to] ?? Int.max) {
                    bestCost[edge.to] = newCost
                    let newState = State(stopIdx: edge.to, cost: newCost, transfers: newTransfers,
                                        parent: current.stopIdx, routeIdx: edge.routeIdx)
                    // Insert sorted (binary search insertion)
                    let insertIdx = pq.firstIndex(where: { $0.cost > newCost }) ?? pq.endIndex
                    pq.insert(newState, at: insertIdx)
                }
            }

            // Early termination: found enough good results
            if bestDestArrivals.count >= 5 { break }
        }

        // Reconstruct journeys from best destination arrivals
        return reconstructJourneys(
            arrivals: bestDestArrivals,
            parentMap: parentMap,
            originStops: originStops,
            destStops: destStops,
            graph: graph,
            timeBucket: timeBucket
        )
    }

    // MARK: - Journey Reconstruction

    private func reconstructJourneys(
        arrivals: [(destIdx: Int, cost: Int, state: State)],
        parentMap: [Int: State],
        originStops: [(index: Int, walkSec: Int)],
        destStops: [(index: Int, walkSec: Int)],
        graph: TransitGraph,
        timeBucket: Int
    ) -> [HeadwayJourney] {
        // Type alias for the State used in parentMap
        typealias State = (stopIdx: Int, cost: Int, transfers: Int, parent: Int, routeIdx: Int)

        let originSet = Set(originStops.map { $0.index })
        let originWalkMap = Dictionary(uniqueKeysWithValues: originStops.map { ($0.index, $0.walkSec) })
        let destWalkMap = Dictionary(uniqueKeysWithValues: destStops.map { ($0.index, $0.walkSec) })

        var journeys: [HeadwayJourney] = []

        for arrival in arrivals {
            var rideLegs: [HeadwayJourney.Leg] = []
            var walkLegs: [HeadwayJourney.WalkLeg] = []

            // Trace back through parent map
            var currentIdx = arrival.destIdx
            var path: [(stopIdx: Int, routeIdx: Int)] = [(currentIdx, arrival.state.routeIdx)]

            while let state = parentMap[currentIdx], state.parent != -1 {
                path.insert((state.parent, state.routeIdx), at: 0)
                currentIdx = state.parent
                if originSet.contains(currentIdx) { break }
                if path.count > 20 { break }  // Safety
            }

            // Convert path to legs
            var i = 0
            while i < path.count - 1 {
                let from = path[i]
                let to = path[i + 1]

                if to.routeIdx == -1 {
                    // Walking
                    walkLegs.append(HeadwayJourney.WalkLeg(
                        fromStopIndex: from.stopIdx, toStopIndex: to.stopIdx,
                        walkSeconds: 120  // Estimate
                    ))
                } else {
                    // Find the route and compute travel time
                    let routeIdx = to.routeIdx
                    guard routeIdx >= 0 && routeIdx < graph.routes.count else { i += 1; continue }
                    let route = graph.routes[routeIdx]
                    let bucket = min(timeBucket, route.cumulativeSeconds.count - 1)
                    let cumulative = route.cumulativeSeconds[max(0, bucket)]
                    let headway = Int(route.headways[min(bucket, route.headways.count - 1)])

                    // Find positions in route
                    let fromStopId = graph.stopIds[from.stopIdx]
                    let toStopId = graph.stopIds[to.stopIdx]
                    let fromPos = route.stopIds.firstIndex(of: fromStopId) ?? 0
                    let toPos = route.stopIds.firstIndex(of: toStopId) ?? fromPos

                    let travelSec = toPos < cumulative.count && fromPos < cumulative.count
                        ? Int(cumulative[toPos]) - Int(cumulative[fromPos])
                        : 120

                    rideLegs.append(HeadwayJourney.Leg(
                        routeName: route.routeName,
                        routeType: route.routeType,
                        boardStopIndex: from.stopIdx,
                        alightStopIndex: to.stopIdx,
                        travelSeconds: max(travelSec, 60),
                        waitSeconds: headway / 2
                    ))
                }
                i += 1
            }

            guard !rideLegs.isEmpty else { continue }

            let originWalk = originWalkMap[path.first?.stopIdx ?? -1] ?? 0
            let destWalk = destWalkMap[arrival.destIdx] ?? 0

            journeys.append(HeadwayJourney(
                rideLegs: rideLegs,
                walkLegs: walkLegs,
                originWalkSeconds: originWalk,
                destWalkSeconds: destWalk,
                totalSeconds: arrival.cost + destWalk
            ))
        }

        // Sort by total time, deduplicate by primary mode
        journeys.sort { $0.totalSeconds < $1.totalSeconds }

        // Keep best per mode
        var seenModes = Set<TransitLegMode>()
        var result: [HeadwayJourney] = []
        for j in journeys {
            if seenModes.insert(j.primaryMode).inserted {
                result.append(j)
            } else if result.count < 5 {
                result.append(j)
            }
        }

        return Array(result.prefix(5))
    }

    // State type for internal Dijkstra use
    private struct State: Comparable {
        let stopIdx: Int
        let cost: Int
        let transfers: Int
        let parent: Int
        let routeIdx: Int
        static func < (lhs: State, rhs: State) -> Bool { lhs.cost < rhs.cost }
    }
}
