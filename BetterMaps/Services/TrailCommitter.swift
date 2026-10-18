import Foundation
import SwiftData

/// Writes a `TrailDraft` to SwiftData. The editor stays a pure value-type
/// editor; this is the only place that turns its points into `Place` rows and
/// a `Trail` record.
@MainActor
enum TrailCommitter {

    /// Default waypoint name for new points.
    static let waypointName = "Waypoint"

    /// Upserts the draft into `layer`.
    ///
    /// - Each draft point becomes a `Place` whose `id` equals the point's id,
    ///   so re-committing the same draft updates rather than duplicates.
    ///   Existing rows keep their name; new rows are named "Waypoint".
    /// - `pathId` comes from `trail` (or is fresh for a new trail),
    ///   `sortIndex` is the point's position, `isWaypointEndpoint` mirrors the
    ///   point's flag.
    /// - Places on this path that are no longer in the draft are deleted.
    /// - The `Trail` is created when `trail` is nil, then updated with name,
    ///   snap flag, geometry and distance.
    /// - `layer.pathNames` is kept in sync for one release so older builds
    ///   reading the same CloudKit store still see the name.
    @discardableResult
    static func commit(_ draft: TrailDraft,
                       geometry: TrailGeometry?,
                       to layer: Layer,
                       trail: Trail?,
                       in context: ModelContext) -> Trail {
        let pathId = trail?.pathId ?? UUID()
        let name = resolvedName(draft.name, layer: layer, isNew: trail == nil)

        let onPath = (layer.places ?? []).filter { $0.pathId == pathId }
        let existingById = Dictionary(onPath.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keep = Set(draft.points.map(\.id))

        for place in onPath where !keep.contains(place.id) {
            removePlace(place, from: layer, in: context)
        }

        if layer.places == nil { layer.places = [] }
        for (index, point) in draft.points.enumerated() {
            let place: Place
            if let existing = existingById[point.id] {
                place = existing
            } else {
                place = Place(name: waypointName, latitude: point.latitude, longitude: point.longitude)
                place.id = point.id
                context.insert(place)
                layer.places?.append(place)
            }
            place.latitude = point.latitude
            place.longitude = point.longitude
            place.isWaypointEndpoint = point.isEndpoint
            place.pathId = pathId
            place.sortIndex = index
            place.updatedAt = Date()
        }

        let target: Trail
        if let trail {
            target = trail
        } else {
            target = Trail(pathId: pathId, name: name)
            context.insert(target)
            target.layer = layer
            if layer.trails == nil { layer.trails = [] }
            if !(layer.trails?.contains { $0.id == target.id } ?? false) {
                layer.trails?.append(target)
            }
        }
        target.name = name
        target.isSnapped = draft.isSnapped
        target.geometry = geometry
        target.distanceMeters = geometry?.totalMeters ?? draft.straightMeters
        target.updatedAt = Date()

        var names = layer.pathNames
        names[pathId] = name
        layer.pathNames = names

        try? context.save()
        TrailSnapshotter.postChange()
        return target
    }

    /// Shows or hides one trail on the map. Bumps `updatedAt` so cached map
    /// snapshots rebuild, saves, and announces the change.
    static func setVisible(_ visible: Bool, for trail: Trail, in context: ModelContext) {
        guard trail.isVisible != visible else { return }
        trail.isVisible = visible
        trail.updatedAt = Date()
        try? context.save()
        TrailSnapshotter.postChange()
    }

    /// Deletes the trail and the `Place`s on its path. A place that is also
    /// in another layer is only unlinked from this one, never deleted.
    static func delete(_ trail: Trail, in context: ModelContext) {
        let pathId = trail.pathId
        if let layer = trail.layer {
            for place in (layer.places ?? []) where place.pathId == pathId {
                removePlace(place, from: layer, in: context)
            }
            layer.trails?.removeAll { $0.id == trail.id }
            var names = layer.pathNames
            names[pathId] = nil
            layer.pathNames = names
        }
        context.delete(trail)
        try? context.save()
        TrailSnapshotter.postChange()
    }

    // MARK: - Helpers

    /// Trimmed draft name, or "Trail N" when blank. N counts the new trail.
    static func resolvedName(_ raw: String, layer: Layer, isNew: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let count = layer.trails?.count ?? 0
        return "Trail \(isNew ? count + 1 : max(count, 1))"
    }

    /// Detaches `place` from `layer` and deletes it unless another layer
    /// still references it.
    private static func removePlace(_ place: Place, from layer: Layer, in context: ModelContext) {
        PlaceCleanup.detach(place, from: layer, in: context)
    }
}
