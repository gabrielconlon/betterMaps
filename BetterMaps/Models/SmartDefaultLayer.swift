import Foundation
import SwiftData
import SwiftUI

/// Pure choices of which layer a quick action lands in, so capture is one
/// tap (Tesler: the app absorbs the "which layer?" decision).
enum SmartDefaultLayer {
    static let fallbackPlaceLayerName = "Favourites"
    static let fallbackTrailLayerName = "Trails"

    /// The tag a dropped pin is saved with: the last used tag while it still
    /// exists, else the first tag by sortOrder. `nil` means no tag exists and
    /// the caller creates "Favourites".
    static func placeLayer(in layers: [LayerLite], lastUsedLayerId: UUID?) -> UUID? {
        let tags = layers.filter { $0.kind == .places }.sorted { $0.sortOrder < $1.sortOrder }
        if let lastUsedLayerId, tags.contains(where: { $0.id == lastUsedLayerId }) {
            return lastUsedLayerId
        }
        return tags.first?.id
    }

    /// The trail layer a new trail from the "+" menu goes in: the last used
    /// trail layer if it still exists, else the first trail layer. `nil`
    /// means the caller creates "Trails".
    static func trailLayer(in layers: [LayerLite], lastTrailLayerId: UUID?) -> UUID? {
        let trailLayers = layers.filter { $0.kind == .waypointPath }.sorted { $0.sortOrder < $1.sortOrder }
        if let lastTrailLayerId, trailLayers.contains(where: { $0.id == lastTrailLayerId }) {
            return lastTrailLayerId
        }
        return trailLayers.first?.id
    }

    /// First palette colour no layer uses yet, cycling when all are taken.
    static func nextColorHex(palette: [String], used: [String]) -> String {
        let taken = Set(used.map { $0.uppercased() })
        if let free = palette.first(where: { !taken.contains($0.uppercased()) }) { return free }
        guard !palette.isEmpty else { return "#007AFF" }
        return palette[used.count % palette.count]
    }
}

extension Layer {
    /// Inserts a new layer at the end of the list with the next unused
    /// palette colour. Used when a quick action needs a layer and none fits.
    @MainActor
    @discardableResult
    static func insertDefault(named name: String, kind: LayerKind, symbolName: String,
                              after existing: [Layer], in context: ModelContext) -> Layer {
        let color = SmartDefaultLayer.nextColorHex(palette: Color.layerPalette.map(\.hex),
                                                   used: existing.map(\.colorHex))
        let layer = Layer(name: name, colorHex: color, symbolName: symbolName,
                          sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1, kind: kind)
        context.insert(layer)
        return layer
    }
}
