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

    /// The Apple Maps result called `name` closest to `coordinate` (a recent
    /// search reopened), or nil when none is within 150 m. Searching by name
    /// keeps a recent café from turning into the shop next door, which a
    /// nearest-POI lookup can do.
    static func item(named name: String, near coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let best = response.mapItems
            .map { ($0, WaypointGraph.meters($0.placemark.coordinate, coordinate)) }
            .min { $0.1 < $1.1 }
        guard let best, best.1 <= 150 else { return nil }
        return best.0
    }
}
