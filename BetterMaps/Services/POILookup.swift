import Foundation
import MapKit

/// Resolves a tapped coordinate to the nearest Apple Maps item: a tight POI
/// search, then a wider one, then reverse geocoding as a last resort.
enum POILookup {
    static func nearestItem(to coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 50)
        if let response = try? await MKLocalSearch(request: request).start(),
           let closest = response.mapItems.first {
            return closest
        }

        let broadRequest = MKLocalPointsOfInterestRequest(center: coordinate, radius: 150)
        if let response = try? await MKLocalSearch(request: broadRequest).start(),
           let closest = response.mapItems
            .sorted(by: {
                WaypointGraph.meters($0.placemark.coordinate, coordinate)
                    < WaypointGraph.meters($1.placemark.coordinate, coordinate)
            })
            .first {
            return closest
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location),
           let placemark = placemarks.first {
            let mapItem = MKMapItem(placemark: MKPlacemark(placemark: placemark))
            mapItem.name = placemark.name ?? placemark.thoroughfare ?? "Tapped Location"
            return mapItem
        }
        return nil
    }
}
