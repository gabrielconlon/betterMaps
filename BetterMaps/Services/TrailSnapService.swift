import Foundation
import CoreLocation
import MapKit

/// Source of walking routes between two coordinates. Abstracted so the snap
/// service can be tested with a canned provider and so a non-MapKit backend
/// can be swapped in later.
protocol DirectionsProviding: Sendable {
    /// Returns the route polyline from `from` to `to`, including both ends.
    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D]
}

/// `MKDirections` with `.walking` transport.
struct MapKitDirectionsProvider: DirectionsProviding {
    init() {}

    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw SnapError.noRoute
        }
        let polyline = route.polyline
        let count = polyline.pointCount
        guard count > 0 else { throw SnapError.noRoute }
        let points = polyline.points()
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(count)
        for i in 0..<count {
            coords.append(points[i].coordinate)
        }
        return coords
    }

    enum SnapError: Error {
        case noRoute
    }
}

/// Snaps a trail's waypoints to walking routes, one directions request per
/// consecutive pair. Results are cached per pair (endpoints rounded to
/// 5 decimal places, roughly 1 m) so re-snapping after moving one point only
/// re-fetches the two segments that touch it.
///
/// A failed or cancelled request degrades that pair to a straight segment
/// (`snapped: false`) instead of failing the whole trail.
actor TrailSnapService {
    private let provider: any DirectionsProviding
    private let maxConcurrent: Int
    private var cache: [String: [CLLocationCoordinate2D]] = [:]

    init(provider: any DirectionsProviding = MapKitDirectionsProvider(), maxConcurrent: Int = 3) {
        self.provider = provider
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Number of cached pair routes. Exposed for tests and diagnostics.
    var cachedPairCount: Int { cache.count }

    func clearCache() { cache.removeAll() }

    /// Snaps each consecutive pair of `points`. Segments come back in the
    /// same order as the pairs regardless of completion order.
    func snap(points: [TrailPoint]) async -> TrailGeometry {
        guard points.count >= 2 else { return TrailGeometry() }

        let pairs: [(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D)] =
            (0..<(points.count - 1)).map { (points[$0].coordinate, points[$0 + 1].coordinate) }

        // Seed from cache; collect the indices that still need a fetch.
        var segments: [TrailGeometry.Segment?] = Array(repeating: nil, count: pairs.count)
        var pending: [Int] = []
        for (i, pair) in pairs.enumerated() {
            if let hit = cache[Self.cacheKey(pair.a, pair.b)] {
                segments[i] = TrailGeometry.Segment(coordinates: hit, snapped: true)
            } else {
                pending.append(i)
            }
        }

        if !pending.isEmpty {
            let provider = self.provider
            let limit = maxConcurrent
            let fetched: [(Int, [CLLocationCoordinate2D]?)] = await withTaskGroup(
                of: (Int, [CLLocationCoordinate2D]?).self
            ) { group in
                var results: [(Int, [CLLocationCoordinate2D]?)] = []
                results.reserveCapacity(pending.count)
                var next = 0

                func enqueue(_ index: Int) {
                    let pair = pairs[index]
                    group.addTask {
                        if Task.isCancelled { return (index, nil) }
                        do {
                            let route = try await provider.walkingRoute(from: pair.a, to: pair.b)
                            return (index, route.count >= 2 ? route : nil)
                        } catch {
                            return (index, nil)
                        }
                    }
                }

                while next < pending.count && next < limit {
                    enqueue(pending[next]); next += 1
                }
                while let result = await group.next() {
                    results.append(result)
                    if next < pending.count {
                        enqueue(pending[next]); next += 1
                    }
                }
                return results
            }

            for (index, route) in fetched {
                let pair = pairs[index]
                if let route {
                    cache[Self.cacheKey(pair.a, pair.b)] = route
                    segments[index] = TrailGeometry.Segment(coordinates: route, snapped: true)
                } else {
                    segments[index] = TrailGeometry.Segment(coordinates: [pair.a, pair.b], snapped: false)
                }
            }
        }

        // Every slot was filled above; the fallback is defensive only.
        return TrailGeometry(segments: segments.enumerated().map { i, seg in
            seg ?? TrailGeometry.Segment(coordinates: [pairs[i].a, pairs[i].b], snapped: false)
        })
    }

    /// Straight segments between consecutive points; no network.
    nonisolated func straight(points: [TrailPoint]) -> TrailGeometry {
        TrailGeometry.straight(through: points.map(\.coordinate))
    }

    // MARK: - Cache key

    /// Both endpoints rounded to 5 dp (~1.1 m) so a sub-meter nudge of a
    /// handle still hits the cache.
    nonisolated static func cacheKey(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        func r(_ v: Double) -> String { String(format: "%.5f", v) }
        return "\(r(a.latitude)),\(r(a.longitude))|\(r(b.latitude)),\(r(b.longitude))"
    }
}
