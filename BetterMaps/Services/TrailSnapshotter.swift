import Foundation
import SwiftData
import CoreLocation

/// Turns the visible waypoint-path layers into `[TrailLite]` for
/// `MapContentStore`. Runs on the main actor because it reads SwiftData
/// models; the expensive/side-effecting `TrailMigrator.ensureTrails` call is
/// cached per layer id + `Fingerprint` (place count, trail count, newest
/// trail `updatedAt`) so it runs once per change, not per body pass. Edits
/// that keep the point count (rename, snap toggle, moved point) bump
/// `updatedAt` and so miss the cache; `invalidate` covers anything else.
@MainActor
final class TrailSnapshotter {
    private struct TrailMeta {
        let id: UUID
        let pathId: UUID
        let name: String
        /// Directions-provider geometry, kept only when the trail is snapped.
        /// Unsnapped trails are rebuilt from their current places every time
        /// so adding or moving a waypoint extends the line immediately.
        let snappedSegments: [TrailSegmentLite]?
    }

    /// Cheap per-layer change detector. Any trail edit committed through
    /// `TrailCommitter` bumps `latestUpdate`; adds/deletes change the counts.
    struct Fingerprint: Equatable, Sendable {
        let placeCount: Int
        let trailCount: Int
        let latestUpdate: Date?

        init(placeCount: Int, trailCount: Int, latestUpdate: Date?) {
            self.placeCount = placeCount
            self.trailCount = trailCount
            self.latestUpdate = latestUpdate
        }

        init(layer: Layer) {
            let trails = layer.trails ?? []
            self.init(placeCount: layer.places?.count ?? 0,
                      trailCount: trails.count,
                      latestUpdate: trails.map(\.updatedAt).max())
        }
    }

    private struct CacheEntry {
        let fingerprint: Fingerprint
        let metas: [TrailMeta]
    }

    private var cache: [UUID: CacheEntry] = [:]

    /// Number of `ensureTrails` rebuilds so far; lets tests observe cache hits.
    private(set) var rebuildCount = 0

    /// Drops the cached trail metadata for one layer.
    func invalidate(layerId: UUID) {
        cache[layerId] = nil
    }

    /// Drops all cached trail metadata.
    func invalidateAll() {
        cache.removeAll()
    }

    func trails(for layers: [Layer], in context: ModelContext) -> [TrailLite] {
        var out: [TrailLite] = []
        for layer in layers where layer.isVisible && layer.kind == .waypointPath {
            let places = layer.places ?? []
            let metas = metas(for: layer, in: context)
            for meta in metas {
                let segments: [TrailSegmentLite]
                if let snapped = meta.snappedSegments, !snapped.isEmpty {
                    segments = snapped
                } else {
                    segments = Self.straightSegments(places.filter { $0.pathId == meta.pathId })
                }
                if let lite = TrailLite(id: meta.id, layerId: layer.id, colorHex: layer.colorHex,
                                        lineWidth: layer.lineWidth, name: meta.name, segments: segments) {
                    out.append(lite)
                }
            }
        }
        return out
    }

    private func metas(for layer: Layer, in context: ModelContext) -> [TrailMeta] {
        if let hit = cache[layer.id], hit.fingerprint == Fingerprint(layer: layer) {
            return hit.metas
        }
        rebuildCount += 1
        let trails = TrailMigrator.ensureTrails(for: layer, in: context)
        let metas = trails.map { trail in
            let snapped: [TrailSegmentLite]?
            if trail.isSnapped, let geometry = trail.geometry, !geometry.isEmpty {
                snapped = geometry.segments.map { TrailSegmentLite(coords: $0.coords, snapped: $0.snapped) }
            } else {
                snapped = nil
            }
            return TrailMeta(id: trail.id, pathId: trail.pathId, name: trail.name, snappedSegments: snapped)
        }
        // Fingerprint after ensureTrails, which may have created trails.
        cache[layer.id] = CacheEntry(fingerprint: Fingerprint(layer: layer), metas: metas)
        return metas
    }

    /// Straight segments through `places` in sortIndex / createdAt order —
    /// the same ordering the pre-Phase-4 renderer used.
    static func straightSegments(_ places: [Place]) -> [TrailSegmentLite] {
        let sorted = places.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
        let nodes = sorted.map {
            WaypointGraph.Node(id: $0.id, coordinate: $0.coordinate, isEndpoint: $0.isWaypointEndpoint, pathId: $0.pathId)
        }
        return WaypointGraph.orderedSegmentsByPath(for: nodes).map {
            TrailSegmentLite(coords: $0.map { [$0.latitude, $0.longitude] }, snapped: false)
        }
    }
}
