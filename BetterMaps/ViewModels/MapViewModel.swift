import SwiftUI
import MapKit
import Observation

// MARK: - Active Sheet Enum (single-sheet pattern)

enum ActiveSheet: Identifiable {
    case placeDetail(Place)
    case poiDetail(MKMapItem)
    case layerSidebar
    case newPlace(CLLocationCoordinate2D)
    case transitArrivals(String, CLLocationCoordinate2D, TransitStop.TransitStopType?, String?, String?)

    var id: String {
        switch self {
        case .placeDetail(let place): return "place-\(place.id)"
        case .poiDetail(let item): return "poi-\(item.name ?? "unknown")-\(item.placemark.coordinate.latitude)"
        case .layerSidebar: return "layerSidebar"
        case .newPlace: return "newPlace"
        case .transitArrivals(let name, _, _, _, _): return "transit-\(name)"
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

    func showTransitArrivals(stationName: String, coordinate: CLLocationCoordinate2D, stopType: TransitStop.TransitStopType? = nil, stopCode: String? = nil, stopId: String? = nil) {
        activeSheet = .transitArrivals(stationName, coordinate, stopType, stopCode, stopId)
    }

    func dismissSheet() {
        activeSheet = nil
    }
}
