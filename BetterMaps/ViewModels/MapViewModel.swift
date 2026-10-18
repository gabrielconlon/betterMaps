import SwiftUI
import MapKit
import Observation

// MARK: - Active Sheet Enum (single-sheet pattern)

enum ActiveSheet: Identifiable {
    case placeDetail(Place)
    case poiDetail(MKMapItem)
    /// New place form. `nil` coordinate starts the pin at the map centre.
    case newPlace(CLLocationCoordinate2D?)
    case transitArrivals(TransitStop)
    case layerDetail(UUID)
    case newLayer
    case editLayer(UUID)
    case trailDetail(UUID)
    case settings

    var id: String {
        switch self {
        case .placeDetail(let place): return "place-\(place.id)"
        case .poiDetail(let item): return "poi-\(item.name ?? "unknown")-\(item.placemark.coordinate.latitude)"
        case .newPlace: return "newPlace"
        case .transitArrivals(let stop): return "transit-\(stop.id)"
        case .layerDetail(let id): return "layer-\(id)"
        case .newLayer: return "newLayer"
        case .editLayer(let id): return "editLayer-\(id)"
        case .trailDetail(let id): return "trail-\(id)"
        case .settings: return "settings"
        }
    }
}

/// A request to open the trail editor. `layerId` is the trail layer the user
/// started from (a LayerCard "Draw" button); `nil` when started from the
/// sheet's "+" menu, where the editor picks or creates the layer.
///
/// TRAIL HOOK: MapScreen observes `MapViewModel.drawTrailRequest`; the trail
/// editor is wired in after the Trails work merges.
struct DrawTrailRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let layerId: UUID?

    init(layerId: UUID?) {
        self.id = UUID()
        self.layerId = layerId
    }
}

@Observable
@MainActor
class MapViewModel {
    var selectedPlace: Place?
    var activeSheet: ActiveSheet?
    var longPressCoordinate: CLLocationCoordinate2D?
    /// TRAIL HOOK: non-nil while the trail editor should be open.
    var drawTrailRequest: DrawTrailRequest?

    func selectPlace(_ place: Place) {
        selectedPlace = place
        activeSheet = .placeDetail(place)
    }

    func showPOI(_ mapItem: MKMapItem) {
        activeSheet = .poiDetail(mapItem)
    }

    func startNewPlace(at coordinate: CLLocationCoordinate2D?) {
        longPressCoordinate = coordinate
        activeSheet = .newPlace(coordinate)
    }

    func showTransitArrivals(for stop: TransitStop) {
        activeSheet = .transitArrivals(stop)
    }

    func showLayerDetail(_ layerId: UUID) {
        activeSheet = .layerDetail(layerId)
    }

    /// TRAIL HOOK: a trail was tapped (map hit-test or list row).
    func showTrailDetail(_ trailId: UUID) {
        activeSheet = .trailDetail(trailId)
    }

    /// TRAIL HOOK: open the trail editor, optionally inside `layerId`.
    func requestDrawTrail(in layerId: UUID?) {
        drawTrailRequest = DrawTrailRequest(layerId: layerId)
    }

    func dismissSheet() {
        activeSheet = nil
    }
}
