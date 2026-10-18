import Foundation
import CoreLocation

/// Finds an already-saved place that a new capture stands for, so saving the
/// same restaurant to a second layer adds a membership instead of a
/// duplicate pin. Overlaps (a place in both Brunch and Favourites) can only
/// form when both saves land on one `Place`. Pure: no SwiftData, no actors.
enum PlaceMatcher {
    /// Same normalised name within this distance is the same place.
    static let sameNameMeters: Double = 30
    /// Any place this close is the same place, whatever it is called
    /// (a dropped pin on top of a saved one).
    static let anyNameMeters: Double = 8

    /// The closest place in `places` that is the same spot: same normalised
    /// name within `maxMeters`, or any name within `anyNameMeters`.
    static func match(name: String,
                      coordinate: CLLocationCoordinate2D,
                      among places: [PlaceLite],
                      maxMeters: Double = sameNameMeters) -> UUID? {
        let key = normalisedName(name)
        var best: (id: UUID, meters: Double)?
        for place in places {
            let meters = distanceMeters(coordinate.latitude, coordinate.longitude,
                                        place.latitude, place.longitude)
            guard meters <= max(maxMeters, anyNameMeters) else { continue }
            let sameName = !key.isEmpty && meters <= maxMeters && normalisedName(place.name) == key
            guard sameName || meters <= anyNameMeters else { continue }
            if best == nil || meters < best!.meters { best = (place.id, meters) }
        }
        return best?.id
    }

    /// Places a capture may merge into: those not on any trail layer, so a
    /// pin dropped on a trail never turns a waypoint into a saved place.
    static func candidates(_ places: [PlaceLite], layers: [LayerLite]) -> [PlaceLite] {
        let trailIds = Set(layers.filter { $0.kind == .waypointPath }.map(\.id))
        guard !trailIds.isEmpty else { return places }
        return places.filter { place in !place.layerIds.contains(where: trailIds.contains) }
    }

    /// Lowercased, accent- and punctuation-free, "&" read as "and", single
    /// spaced: "Café  Nero!" and "cafe nero" compare equal.
    static func normalisedName(_ name: String) -> String {
        name.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Great-circle distance in metres (haversine).
    static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
