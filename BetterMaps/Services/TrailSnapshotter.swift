import Foundation
import SwiftData
import CoreLocation

/// Turns the visible waypoint-path layers into `[TrailLite]` for
/// `MapContentStore`. Runs on the main actor because it reads SwiftData
/// models; the expensive/side-effecting `TrailMigrator.ensureTrails` call is
/// cached per layer id + `Fingerprint` (place count, trail count, newest
/// trail `updatedAt`) so it runs once per change, not per body pass. Edits
/// that keep the point count (rename, snap toggle, moved point, show/hide)
/// bump `updatedAt` and so miss the cache; `invalidate` covers anything else.
/// Hidden trails (`Trail.isVisible == false`) are never returned.
///
/// The screen learns that trails changed without a places/layers change in
/// two ways: `didChangeNotification`, posted by every local trail write, and
/// `fingerprint(in:)`, a cheap store-wide check that also catches CloudKit
/// imports.
@MainActor
final class TrailSnapshotter {
    /// Posted on the main actor after any local trail write (commit, delete,
    /// show/hide, layer delete).
    nonisolated static let didChangeNotification = Notification.Name("TrailSnapshotter.didChange")

    static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Store-wide change detector: number of trails plus the newest
    /// `updatedAt`. Two small fetches; cheap enough for a body pass.
    struct StoreFingerprint: Equatable, Sendable {
        let trailCount: Int
        let latestUpdate: Date?
    }

    static func fingerprint(in context: ModelContext) -> StoreFingerprint {
        let count = (try? context.fetchCount(FetchDescriptor<Trail>())) ?? 0
        var newest = FetchDescriptor<Trail>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        newest.fetchLimit = 1
        newest.propertiesToFetch = [\.updatedAt]
        let latest = (try? context.fetch(newest))?.first?.updatedAt
        return StoreFingerprint(trailCount: count, latestUpdate: latest)
    }

    private struct TrailMeta {
        let id: UUID
        let pathId: UUID
        let name: String
        let isVisible: Bool
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
        let hiddenCount: Int

        init(placeCount: Int, trailCount: Int, latestUpdate: Date?, hiddenCount: Int = 0) {
            self.placeCount = placeCount
            self.trailCount = trailCount
            self.latestUpdate = latestUpdate
            self.hiddenCount = hiddenCount
        }

        init(layer: Layer) {
            let trails = layer.trails ?? []
            self.init(placeCount: layer.places?.count ?? 0,
                      trailCount: trails.count,
                      latestUpdate: trails.map(\.updatedAt).max(),
                      hiddenCount: trails.filter { !$0.isVisible }.count)
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
            for meta in metas where meta.isVisible {
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
            return TrailMeta(id: trail.id, pathId: trail.pathId, name: trail.name,
                             isVisible: trail.isVisible, snappedSegments: snapped)
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
