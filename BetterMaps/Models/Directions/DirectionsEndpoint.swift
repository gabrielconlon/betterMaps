import Foundation
import CoreLocation

/// Either end of a directions request as the user sees it: a name to show
/// and the coordinate to plan from. Equality rounds the coordinate to six
/// decimal places (about 10 cm) so two searches for the same place match.
struct DirectionsEndpoint: Hashable, Sendable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let isUserLocation: Bool

    init(name: String, coordinate: CLLocationCoordinate2D, isUserLocation: Bool = false) {
        self.name = name
        self.coordinate = coordinate
        self.isUserLocation = isUserLocation
    }

    static func userLocation(_ coordinate: CLLocationCoordinate2D) -> DirectionsEndpoint {
        DirectionsEndpoint(name: "My Location", coordinate: coordinate, isUserLocation: true)
    }

    private static func rounded(_ value: Double) -> Int64 {
        Int64((value * 1_000_000).rounded())
    }

    static func == (lhs: DirectionsEndpoint, rhs: DirectionsEndpoint) -> Bool {
        lhs.name == rhs.name
            && lhs.isUserLocation == rhs.isUserLocation
            && rounded(lhs.coordinate.latitude) == rounded(rhs.coordinate.latitude)
            && rounded(lhs.coordinate.longitude) == rounded(rhs.coordinate.longitude)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(isUserLocation)
        hasher.combine(Self.rounded(coordinate.latitude))
        hasher.combine(Self.rounded(coordinate.longitude))
    }
}
