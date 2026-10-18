import Foundation
import SwiftData
import CoreLocation

/// A named trail inside a waypoint-path `Layer`.
///
/// Today a trail's points are the layer's `Place`s sharing `pathId`
/// (ordered by sortIndex, then createdAt). `Trail` is the record that
/// carries per-trail metadata — name, snapped-to-roads flag, cached
/// geometry and distance — so the renderer doesn't have to recompute or
/// re-fetch directions on every draw.
///
/// CloudKit-safe: every stored property has a default, no unique
/// constraints, no dictionaries, optional relationship with a default.
@Model
final class Trail {
    var id: UUID = UUID()
    /// Matches `Place.pathId` for the waypoints that make up this trail.
    var pathId: UUID = UUID()
    var name: String = ""
    /// True when `geometryData` was produced by a directions provider rather
    /// than straight lines between waypoints.
    var isSnapped: Bool = false
    /// Cached total length of `geometry` in meters.
    var distanceMeters: Double = 0
    /// JSON-encoded `TrailGeometry`. Access through `geometry`.
    @Attribute(.externalStorage)
    var geometryData: Data? = nil
    var layer: Layer? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        pathId: UUID = UUID(),
        name: String = "",
        isSnapped: Bool = false,
        distanceMeters: Double = 0,
        geometryData: Data? = nil,
        layer: Layer? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.pathId = pathId
        self.name = name
        self.isSnapped = isSnapped
        self.distanceMeters = distanceMeters
        self.geometryData = geometryData
        self.layer = layer
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// Polyline geometry for a trail: one segment per consecutive waypoint pair.
/// Coordinates are `[latitude, longitude]` pairs so the JSON stays compact
/// and schema-free.
struct TrailGeometry: Codable, Sendable, Equatable {
    struct Segment: Codable, Sendable, Equatable {
        /// `[[lat, lon], ...]`. Pairs with fewer than two numbers are ignored.
        var coords: [[Double]]
        /// True when the coords came from a directions provider.
        var snapped: Bool

        init(coords: [[Double]], snapped: Bool) {
            self.coords = coords
            self.snapped = snapped
        }

        init(coordinates: [CLLocationCoordinate2D], snapped: Bool) {
            self.coords = coordinates.map { [$0.latitude, $0.longitude] }
            self.snapped = snapped
        }

        var coordinates: [CLLocationCoordinate2D] {
            coords.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
        }

        /// Length of this segment's polyline in meters.
        var meters: Double {
            let c = coordinates
            guard c.count >= 2 else { return 0 }
            var total = 0.0
            for i in 0..<(c.count - 1) {
                total += WaypointGraph.meters(c[i], c[i + 1])
            }
            return total
        }
    }

    var segments: [Segment]

    init(segments: [Segment] = []) {
        self.segments = segments
    }

    /// Sum of every segment's polyline length, via `WaypointGraph.meters`.
    var totalMeters: Double {
        segments.reduce(0) { $0 + $1.meters }
    }

    var isEmpty: Bool { segments.isEmpty }

    /// Straight-line geometry through `coordinates` in order.
    static func straight(through coordinates: [CLLocationCoordinate2D]) -> TrailGeometry {
        guard coordinates.count >= 2 else { return TrailGeometry() }
        var segs: [Segment] = []
        segs.reserveCapacity(coordinates.count - 1)
        for i in 0..<(coordinates.count - 1) {
            segs.append(Segment(coordinates: [coordinates[i], coordinates[i + 1]], snapped: false))
        }
        return TrailGeometry(segments: segs)
    }
}

extension Trail {
    /// Decoded view of `geometryData`. Setting `nil` clears the data. A
    /// malformed blob reads as `nil` instead of crashing.
    var geometry: TrailGeometry? {
        get {
            guard let data = geometryData else { return nil }
            return try? JSONDecoder().decode(TrailGeometry.self, from: data)
        }
        set {
            guard let newValue else { geometryData = nil; return }
            geometryData = try? JSONEncoder().encode(newValue)
        }
    }
}
