import Foundation
import SwiftData

/// Lazily creates `Trail` records for waypoint-path layers that predate the
/// `Trail` model. Idempotent: running it twice adds nothing the second time.
@MainActor
enum TrailMigrator {

    /// Ensures every distinct `pathId` among `layer.places` has a `Trail`.
    ///
    /// - Places with a nil `pathId` are the legacy single bucket: they are all
    ///   assigned one fresh shared `pathId` and become one trail.
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
        let places = layer.places ?? []

        // Legacy bucket: nil pathId → one shared fresh id.
        let legacy = places.filter { $0.pathId == nil }
        if !legacy.isEmpty {
            let shared = UUID()
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

        var trails = layer.trails ?? []
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

        return trails.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
