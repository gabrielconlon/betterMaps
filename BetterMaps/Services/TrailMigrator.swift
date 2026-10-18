import Foundation
import SwiftData

/// Lazily creates `Trail` records for waypoint-path layers that predate the
/// `Trail` model, and repairs duplicate trails that CloudKit can produce when
/// two devices migrate the same layer. Idempotent: running it twice changes
/// nothing the second time.
@MainActor
enum TrailMigrator {

    /// Ensures every distinct `pathId` among the layer's trail waypoints has
    /// exactly one `Trail`.
    ///
    /// - Only trail waypoints are touched: a place that also belongs to a
    ///   `.places` layer is a saved place, never a waypoint, and is never
    ///   given a `pathId` here.
    /// - Places with a nil `pathId` are the legacy single bucket. They share
    ///   `legacyPathId(for: layer.id)`, derived from the layer id so every
    ///   device picks the same id and their trails merge on sync. A nil-pathId
    ///   place only joins the bucket when it looks like a waypoint (named
    ///   "Waypoint", flagged as an endpoint, or carrying no notes, rating or
    ///   tags) so places from a layer whose type was switched stay untouched.
    /// - Several trails with the same `pathId` are collapsed to one: the
    ///   snapped one, else the earliest `createdAt`. The rest are deleted.
    /// - A new trail is named from `layer.pathNames[pathId]`, or "Trail N"
    ///   where N is its 1-based position among all of the layer's trails.
    /// - New trails get straight-line geometry and distance from the places
    ///   in sortIndex/createdAt order, and `createdAt` of the earliest place
    ///   so the returned order matches authoring order.
    /// - Does not call `context.save()`; the caller decides when to save.
    ///
    /// Returns the layer's trails sorted by `createdAt`.
    @discardableResult
    static func ensureTrails(for layer: Layer, in context: ModelContext) -> [Trail] {
        let places = (layer.places ?? []).filter { !isSavedPlace($0, outside: layer) }

        // Legacy bucket: nil pathId → one shared, deterministic id.
        let legacy = places.filter { $0.pathId == nil && looksLikeWaypoint($0) }
        if !legacy.isEmpty {
            let shared = legacyPathId(for: layer.id)
            for place in legacy { place.pathId = shared }
        }

        // Distinct pathIds in a deterministic order (earliest place first).
        var earliest: [UUID: Date] = [:]
        var membersById: [UUID: [Place]] = [:]
        for place in places {
            guard let pid = place.pathId else { continue }
            membersById[pid, default: []].append(place)
            if let cur = earliest[pid] {
                earliest[pid] = min(cur, place.createdAt)
            } else {
                earliest[pid] = place.createdAt
            }
        }
        let orderedPathIds = earliest.keys.sorted { lhs, rhs in
            let l = earliest[lhs] ?? .distantPast
            let r = earliest[rhs] ?? .distantPast
            if l != r { return l < r }
            return lhs.uuidString < rhs.uuidString
        }

        var trails = dedupe(layer.trails ?? [], in: layer, context: context)
        let existingPathIds = Set(trails.map(\.pathId))
        let names = layer.pathNames

        for pid in orderedPathIds where !existingPathIds.contains(pid) {
            let members = (membersById[pid] ?? []).sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
            let geometry = TrailGeometry.straight(through: members.map(\.coordinate))
            let trail = Trail(
                pathId: pid,
                name: names[pid] ?? "Trail \(trails.count + 1)",
                isSnapped: false,
                distanceMeters: geometry.totalMeters,
                geometryData: try? JSONEncoder().encode(geometry),
                createdAt: earliest[pid] ?? Date()
            )
            context.insert(trail)
            trail.layer = layer
            trails.append(trail)
        }

        if layer.trails == nil { layer.trails = [] }
        for trail in trails where !(layer.trails?.contains { $0.id == trail.id } ?? false) {
            layer.trails?.append(trail)
        }

        return trails.sorted(by: earlierFirst)
    }

    // MARK: - Legacy id

    /// Fixed mask XORed into the layer id. Any constant works as long as it
    /// never changes: every device must derive the same id.
    private static let legacyMask: [UInt8] = [
        0x5A, 0x1C, 0xE3, 0x72, 0x9B, 0x04, 0xD6, 0x3F,
        0xA8, 0x61, 0x2E, 0xB7, 0x45, 0xF0, 0x19, 0x8D,
    ]

    /// The `pathId` shared by a layer's legacy (nil-pathId) waypoints:
    /// `layerId` with a fixed XOR, so it is stable across launches and devices
    /// and never equal to the layer id itself.
    static func legacyPathId(for layerId: UUID) -> UUID {
        var bytes = layerId.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<raw.count { raw[i] ^= legacyMask[i] }
        }
        return UUID(uuid: bytes)
    }

    // MARK: - Helpers

    /// True when `place` is also in a `.places` layer other than `layer`:
    /// a saved place, never a waypoint.
    static func isSavedPlace(_ place: Place, outside layer: Layer) -> Bool {
        (place.layers ?? []).contains { $0.id != layer.id && $0.kind == .places }
    }

    /// Heuristic for nil-pathId places: waypoints are created named
    /// "Waypoint" and carry no user content.
    static func looksLikeWaypoint(_ place: Place) -> Bool {
        if place.name == TrailCommitter.waypointName || place.isWaypointEndpoint { return true }
        return place.notes.isEmpty && place.rating == 0 && place.tags.isEmpty
    }

    /// Keeps one trail per `pathId` (snapped first, then earliest
    /// `createdAt`, then id) and deletes the others. Returns the survivors.
    static func dedupe(_ trails: [Trail], in layer: Layer, context: ModelContext) -> [Trail] {
        var byPath: [UUID: [Trail]] = [:]
        for trail in trails { byPath[trail.pathId, default: []].append(trail) }
        guard byPath.values.contains(where: { $0.count > 1 }) else { return trails }

        var keep: [Trail] = []
        var dropIds: Set<UUID> = []
        for group in byPath.values {
            let ranked = group.sorted { lhs, rhs in
                if lhs.isSnapped != rhs.isSnapped { return lhs.isSnapped }
                return earlierFirst(lhs, rhs)
            }
            keep.append(ranked[0])
            for extra in ranked.dropFirst() {
                dropIds.insert(extra.id)
                context.delete(extra)
            }
        }
        layer.trails?.removeAll { dropIds.contains($0.id) }
        return keep
    }

    private static func earlierFirst(_ lhs: Trail, _ rhs: Trail) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
