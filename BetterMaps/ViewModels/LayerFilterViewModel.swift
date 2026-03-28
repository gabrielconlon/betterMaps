import SwiftUI
import Observation

enum FilterMode: String, CaseIterable {
    case union = "Combined"
    case intersection = "Overlap Only"

    var description: String {
        switch self {
        case .union: return "Show places from any active layer"
        case .intersection: return "Show only places in all active layers"
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
    var filterMode: FilterMode = .union

    func filteredPlaces(allPlaces: [Place], allLayers: [Layer]) -> [Place] {
        let activeLayers = allLayers.filter { $0.isVisible }
        guard !activeLayers.isEmpty else { return [] }

        let activeLayerIDs = Set(activeLayers.map { $0.id })

        switch filterMode {
        case .union:
            return unionFilter(allPlaces: allPlaces, activeLayerIDs: activeLayerIDs)
        case .intersection:
            return intersectionFilter(
                allPlaces: allPlaces,
                activeLayerIDs: activeLayerIDs,
                requiredCount: activeLayers.count
            )
        }
    }

    private func unionFilter(allPlaces: [Place], activeLayerIDs: Set<UUID>) -> [Place] {
        allPlaces.filter { place in
            guard let placeLayers = place.layers else { return false }
            return placeLayers.contains { activeLayerIDs.contains($0.id) }
        }
    }

    private func intersectionFilter(
        allPlaces: [Place],
        activeLayerIDs: Set<UUID>,
        requiredCount: Int
    ) -> [Place] {
        allPlaces.filter { place in
            guard let placeLayers = place.layers else { return false }
            let matchCount = placeLayers.filter { activeLayerIDs.contains($0.id) }.count
            return matchCount == requiredCount
        }
    }
}
