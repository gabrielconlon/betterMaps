import Foundation
import CoreLocation

/// Connects an unordered set of waypoints into one or more chains.
///
/// Algorithm: greedy edge addition.
/// 1. Each point has a degree cap — 1 if marked as start/end, otherwise 2.
/// 2. Walk all candidate edges in order of shortest distance.
/// 3. Accept an edge only if both endpoints still have remaining capacity AND adding
///    the edge would not form a cycle.
///
/// Cycle prevention is what avoids triangles: a triangle requires a third edge that
/// closes a loop between three already-connected points, and union-find rejects it.
/// The result is always a forest of disjoint chains.
enum WaypointGraph {

    struct Node {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let isEndpoint: Bool
    }

    /// Returns segments as pairs of coordinates, ready to feed to `MapPolyline(coordinates:)`.
    static func segments(for nodes: [Node]) -> [[CLLocationCoordinate2D]] {
        guard nodes.count >= 2 else { return [] }

        let coordIndex: [UUID: CLLocationCoordinate2D] = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, $0.coordinate) }
        )
        let maxDegree: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, $0.isEndpoint ? 1 : 2) }
        )

        // All unique candidate edges, sorted by distance ascending.
        var candidates: [(a: UUID, b: UUID, dist: Double)] = []
        candidates.reserveCapacity(nodes.count * (nodes.count - 1) / 2)
        for i in 0..<nodes.count {
            let li = CLLocation(latitude: nodes[i].coordinate.latitude,
                                longitude: nodes[i].coordinate.longitude)
            for j in (i + 1)..<nodes.count {
                let lj = CLLocation(latitude: nodes[j].coordinate.latitude,
                                    longitude: nodes[j].coordinate.longitude)
                candidates.append((nodes[i].id, nodes[j].id, li.distance(from: lj)))
            }
        }
        candidates.sort { $0.dist < $1.dist }

        var degree: [UUID: Int] = [:]
        var uf = UnionFind()
        var chosen: [(UUID, UUID)] = []

        for cand in candidates {
            let aDeg = degree[cand.a, default: 0]
            let bDeg = degree[cand.b, default: 0]
            let aMax = maxDegree[cand.a] ?? 2
            let bMax = maxDegree[cand.b] ?? 2
            guard aDeg < aMax, bDeg < bMax else { continue }
            guard uf.union(cand.a, cand.b) else { continue }

            chosen.append((cand.a, cand.b))
            degree[cand.a] = aDeg + 1
            degree[cand.b] = bDeg + 1
        }

        return chosen.compactMap { pair in
            guard let a = coordIndex[pair.0], let b = coordIndex[pair.1] else { return nil }
            return [a, b]
        }
    }
}

private struct UnionFind {
    private var parent: [UUID: UUID] = [:]

    mutating func find(_ x: UUID) -> UUID {
        if parent[x] == nil { parent[x] = x; return x }
        var root = x
        while let p = parent[root], p != root { root = p }
        // Path compression
        var cur = x
        while let p = parent[cur], p != root {
            parent[cur] = root
            cur = p
        }
        return root
    }

    /// Returns true if a and b were in different sets (and have now been merged).
    /// Returns false if a and b were already connected (would form a cycle).
    mutating func union(_ a: UUID, _ b: UUID) -> Bool {
        let ra = find(a)
        let rb = find(b)
        if ra == rb { return false }
        parent[ra] = rb
        return true
    }
}
