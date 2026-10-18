import Foundation
import MapKit

/// Resolves a tapped coordinate to the nearest Apple Maps item: a tight POI
/// search, then a wider one, then reverse geocoding as a last resort. The
/// MapKit calls are shared with `PlaceLookupService` via `MapKitLookups`.
enum POILookup {
    static func nearestItem(to coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        if let close = await MapKitLookups.nearestPOI(to: coordinate, radius: 50) {
            return close
        }
        guard !Task.isCancelled else { return nil }
        if let broad = await MapKitLookups.nearestPOI(to: coordinate, radius: 150) {
            return broad
        }
        guard !Task.isCancelled else { return nil }
        if let placemark = await MapKitLookups.reverseGeocode(coordinate) {
            let mapItem = MKMapItem(placemark: MKPlacemark(placemark: placemark))
            mapItem.name = placemark.name ?? placemark.thoroughfare ?? "Tapped Location"
            return mapItem
        }
        return nil
    }
}
