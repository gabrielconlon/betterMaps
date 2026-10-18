import SwiftUI
import MapKit
import Observation

// MARK: - Active Sheet Enum (single-sheet pattern)

enum ActiveSheet: Identifiable {
    case placeDetail(Place)
    case poiDetail(MKMapItem)
    case layerSidebar
    case newPlace(CLLocationCoordinate2D)
    case transitArrivals(TransitStop)

    var id: String {
        switch self {
        case .placeDetail(let place): return "place-\(place.id)"
        case .poiDetail(let item): return "poi-\(item.name ?? "unknown")-\(item.placemark.coordinate.latitude)"
        case .layerSidebar: return "layerSidebar"
        case .newPlace: return "newPlace"
        case .transitArrivals(let stop): return "transit-\(stop.id)"
        }
    }
}

@Observable
@MainActor
class MapViewModel {
    var selectedPlace: Place?
    var activeSheet: ActiveSheet?
    var longPressCoordinate: CLLocationCoordinate2D?

    func selectPlace(_ place: Place) {
        selectedPlace = place
        activeSheet = .placeDetail(place)
    }

    func showPOI(_ mapItem: MKMapItem) {
        activeSheet = .poiDetail(mapItem)
    }

    func showLayerSidebar() {
        activeSheet = .layerSidebar
    }

    func startNewPlace(at coordinate: CLLocationCoordinate2D) {
        longPressCoordinate = coordinate
        activeSheet = .newPlace(coordinate)
    }

    func showTransitArrivals(for stop: TransitStop) {
        activeSheet = .transitArrivals(stop)
    }

    func dismissSheet() {
        activeSheet = nil
    }
}
