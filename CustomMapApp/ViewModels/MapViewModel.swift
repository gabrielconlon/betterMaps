import SwiftUI
import MapKit
import Observation

// MARK: - Active Sheet Enum (single-sheet pattern)

struct RouteContext {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

enum ActiveSheet: Identifiable {
    case placeDetail(Place)
    case poiDetail(MKMapItem)
    case layerSidebar
    case routing(RouteContext?)
    case newPlace(CLLocationCoordinate2D)
    case transitArrivals(String, CLLocationCoordinate2D) // stationName, coordinate

    var id: String {
        switch self {
        case .placeDetail(let place): return "place-\(place.id)"
        case .poiDetail(let item): return "poi-\(item.name ?? "unknown")-\(item.placemark.coordinate.latitude)"
        case .layerSidebar: return "layerSidebar"
        case .routing: return "routing"
        case .newPlace: return "newPlace"
        case .transitArrivals(let name, _): return "transit-\(name)"
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

    func showRouting(context: RouteContext? = nil) {
        activeSheet = .routing(context)
    }

    func startNewPlace(at coordinate: CLLocationCoordinate2D) {
        longPressCoordinate = coordinate
        activeSheet = .newPlace(coordinate)
    }

    func showTransitArrivals(stationName: String, coordinate: CLLocationCoordinate2D) {
        activeSheet = .transitArrivals(stationName, coordinate)
    }

    func dismissSheet() {
        activeSheet = nil
    }
}
