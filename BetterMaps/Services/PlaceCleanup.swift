import Foundation
import SwiftData

/// Removing places from layers without leaving orphans. A `Place` with no
/// layers is invisible everywhere in the app, so whenever a place loses its
/// last layer it is deleted; a place still in another layer is only unlinked.
@MainActor
enum PlaceCleanup {

    /// Unlinks `place` from `layer`, and deletes it if no other layer still
    /// holds it. Does not save; the caller decides when.
    static func detach(_ place: Place, from layer: Layer, in context: ModelContext) {
        layer.places?.removeAll { $0.id == place.id }
        // Filter by id rather than trusting the inverse to have updated yet.
        let others = (place.layers ?? []).filter { $0.id != layer.id }
        if others.isEmpty {
            context.delete(place)
        }
    }

    /// Deletes `layer`: its trails (cascade), its links to places, and every
    /// place that was only in this layer. Places also in another layer stay.
    /// Saves the context.
    static func deleteLayer(_ layer: Layer, in context: ModelContext) {
        for trail in layer.trails ?? [] {
            context.delete(trail)
        }
        layer.trails = []
        for place in layer.places ?? [] {
            detach(place, from: layer, in: context)
        }
        context.delete(layer)
        try? context.save()
        TrailSnapshotter.postChange()
    }
}
