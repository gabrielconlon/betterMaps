import Foundation
import CoreLocation

/// Geographic helpers for waypoint paths: Haversine distance and
/// tap-order polylines grouped by `pathId`.
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
        /// Groups nodes into independent paths. Nodes with different pathIds
        /// never share an edge. nil is treated as one shared legacy bucket.
        var pathId: UUID? = nil
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
}
