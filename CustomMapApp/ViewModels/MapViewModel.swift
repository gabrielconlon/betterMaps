import SwiftUI
import MapKit
import Observation

@Observable
@MainActor
class MapViewModel {
    var selectedPlace: Place?
    var showPlaceDetail = false
    var showEditPlace = false
    var showNewPlaceForm = false
    var longPressCoordinate: CLLocationCoordinate2D?

    func selectPlace(_ place: Place) {
        selectedPlace = place
        showPlaceDetail = true
    }

    func startNewPlace(at coordinate: CLLocationCoordinate2D) {
        longPressCoordinate = coordinate
        showNewPlaceForm = true
    }
}
