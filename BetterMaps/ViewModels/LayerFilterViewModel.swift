import SwiftUI
import Observation

enum FilterMode: String, CaseIterable, Sendable {
    case union = "Any Layer"
    case intersection = "All Layers"

    var description: String {
        switch self {
        case .union: return "Show places in any active layer"
        case .intersection: return "Show only places shared by all active layers"
        }
    }

    var systemImage: String {
        switch self {
        case .union: return "circle.grid.2x2"
        case .intersection: return "circle.and.line.horizontal"
        }
    }
}

@Observable
@MainActor
class LayerFilterViewModel {
    /// UserDefaults key under which `filterMode` is persisted.
    static let filterModeDefaultsKey = "layerFilterMode"

    @ObservationIgnored private let defaults: UserDefaults

    /// Persisted across launches. Written on every set, read once on init.
    var filterMode: FilterMode {
        didSet { defaults.set(filterMode.rawValue, forKey: Self.filterModeDefaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.filterModeDefaultsKey),
           let mode = FilterMode(rawValue: raw) {
            self.filterMode = mode
        } else {
            self.filterMode = .union
        }
    }

    /// Places that pass the current filter mode, in the order of `allPlaces`.
    /// Delegates to `LayerMath.filter`, so trail (waypoint-path) layers are
    /// never counted toward intersection and trail-only pins are shown only
    /// at endpoints.
    func filteredPlaces(allPlaces: [Place], allLayers: [Layer]) -> [Place] {
        let matched = matchedPlaces(allPlaces: allPlaces, allLayers: allLayers)
        let keep = Set(matched.map(\.id))
        return allPlaces.filter { keep.contains($0.id) }
    }

    /// Same filter as `filteredPlaces` but returns the match metadata
    /// (match count, primary layer) for callers that style pins or build the
    /// intersection legend.
    func matchedPlaces(allPlaces: [Place], allLayers: [Layer]) -> [MatchedPlace] {
        let layers = allLayers.map(LayerLite.init)
        let places = allPlaces.map(PlaceLite.init)
        return LayerMath.filter(places, layers: layers, mode: filterMode)
    }
}
