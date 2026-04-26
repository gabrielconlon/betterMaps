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

    /// Distance in meters between two coordinates via the Haversine formula.
    /// Uses raw Double arithmetic — no CLLocation allocation, no system call —
    /// so it avoids the kernel's CoreLocation API rate limit (~24k/sec).
    /// The previous codebase used `CLLocation(...).distance(from:)` in
    /// hot loops that iterated all ~14k transit stops on every routing
    /// search; on multi-search sessions that tripped the limit and stalled
    /// the main thread for ~60 seconds with the white-screen hang the user
    /// reported. Use this helper for any geographic distance check.
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) +
                cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    struct Node {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let isEndpoint: Bool
        /// Groups nodes into independent paths within the same set. Nodes with the
        /// same pathId are connected via the MST algorithm; nodes with different
        /// pathIds never share an edge — even if their coords are close. nil means
        /// "ungrouped" and is treated as one shared bucket so legacy waypoints
        /// (pre-multi-path) keep rendering as a single line.
        var pathId: UUID? = nil
    }

    /// Multi-path segment computation: groups nodes by `pathId`, runs the MST
    /// algorithm independently per group, and returns the flattened polylines.
    /// This is what prevents an unrelated trail in the same layer from getting
    /// connected to its neighbor by a phantom shortest-edge.
    ///
    /// Use `orderedSegmentsByPath` for actual trail authoring — MST is fine for
    /// "auto-connect a small unordered set" but is wrong for paths along
    /// non-convex routes (canals, winding roads) where the user's intended
    /// order matters more than geometric proximity.
    static func segmentsByPath(for nodes: [Node]) -> [[CLLocationCoordinate2D]] {
        guard !nodes.isEmpty else { return [] }
        // Bucket by pathId. nil pathIds collapse into a single shared bucket so
        // pre-existing waypoints (created before the field existed) still render.
        var groups: [UUID?: [Node]] = [:]
        for node in nodes { groups[node.pathId, default: []].append(node) }
        var result: [[CLLocationCoordinate2D]] = []
        for (_, group) in groups {
            result.append(contentsOf: segments(for: group))
        }
        return result
    }

    /// Connects nodes in the order they appear in the input array — i.e.,
    /// nodes[0] → nodes[1] → ... → nodes[n-1]. Trusts the caller to have
    /// pre-sorted by sortIndex / createdAt.
    ///
    /// This replaces MST for waypoint-path layers because MST silently
    /// rewires the topology whenever endpoint flags or geometry change in
    /// ways that produce a different shortest-edge set. The user's mental
    /// model is "I tapped these points in this order, draw a line through
    /// them in that order" — Strava, Mapbox Studio, Google My Maps all
    /// behave this way. With ordered traversal, the `isEndpoint` flag
    /// becomes purely visual (the flag icon on the start/end pin); it has
    /// no effect on which lines are drawn.
    static func orderedSegments(for nodes: [Node]) -> [[CLLocationCoordinate2D]] {
        guard nodes.count >= 2 else { return [] }
        var segs: [[CLLocationCoordinate2D]] = []
        segs.reserveCapacity(nodes.count - 1)
        for i in 0..<(nodes.count - 1) {
            segs.append([nodes[i].coordinate, nodes[i + 1].coordinate])
        }
        return segs
    }

    /// Per-path ordered segments. Bucket by pathId, preserve input order
    /// within each bucket (caller pre-sorts), connect in sequence.
    static func orderedSegmentsByPath(for nodes: [Node]) -> [[CLLocationCoordinate2D]] {
        guard !nodes.isEmpty else { return [] }
        var groups: [UUID?: [Node]] = [:]
        var insertionOrder: [UUID?] = []  // preserve outer ordering for determinism
        for node in nodes {
            if groups[node.pathId] == nil { insertionOrder.append(node.pathId) }
            groups[node.pathId, default: []].append(node)
        }
        var result: [[CLLocationCoordinate2D]] = []
        for key in insertionOrder {
            if let group = groups[key] {
                result.append(contentsOf: orderedSegments(for: group))
            }
        }
        return result
    }

    /// Returns segments as pairs of coordinates, ready to feed to `MapPolyline(coordinates:)`.
    /// Use `segmentsByPath` when waypoints may belong to multiple independent paths;
    /// this single-group method is kept for tests and callers that already know they
    /// have one connected set.
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
