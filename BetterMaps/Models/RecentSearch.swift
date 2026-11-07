import Foundation
import CoreLocation

/// One end of a remembered journey. "My Location" is kept as a flag, not a
/// coordinate: reusing the journey starts from wherever the user is now.
struct RecentEndpoint: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var isUserLocation: Bool

    init(_ endpoint: DirectionsEndpoint) {
        name = endpoint.name
        latitude = endpoint.coordinate.latitude
        longitude = endpoint.coordinate.longitude
        isUserLocation = endpoint.isUserLocation
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var endpoint: DirectionsEndpoint {
        DirectionsEndpoint(name: name, coordinate: coordinate, isUserLocation: isUserLocation)
    }

    /// Same place to the user: both "My Location", or the same name within
    /// about 10 m (a POI's coordinate moves a little between lookups).
    func matches(_ other: RecentEndpoint) -> Bool {
        if isUserLocation || other.isUserLocation { return isUserLocation == other.isUserLocation }
        return name == other.name
            && abs(latitude - other.latitude) < 0.0001
            && abs(longitude - other.longitude) < 0.0001
    }
}

/// Something the user searched for and opened: a place (saved, a stop, or
/// an Apple Maps result), a transit route, or a journey from A to B.
///
/// Rows carry what they need to draw themselves, so the list renders
/// without the transit bundle or the store being loaded, and what they
/// need to reopen: a saved place or stop by id, an Apple Maps result by
/// name near its coordinate, a journey by its two ends.
struct RecentSearch: Codable, Hashable, Sendable, Identifiable {
    enum Kind: Codable, Hashable, Sendable {
        case savedPlace(id: UUID, tagColorHex: String?)
        case stop(id: String, kind: TransitLayerKind, line: String?, code: String?)
        case poi
        case transitRoute(id: String, short: String, long: String, type: Int)
        case journey(origin: RecentEndpoint, destination: RecentEndpoint)
    }

    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double
    var date: Date = Date()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Two entries are the same search when reusing either would open the
    /// same thing; the newer one replaces the older.
    func isSameSearch(as other: RecentSearch) -> Bool {
        switch (kind, other.kind) {
        case let (.savedPlace(a, _), .savedPlace(b, _)): return a == b
        case let (.stop(a, _, _, _), .stop(b, _, _, _)): return a == b
        case let (.transitRoute(a, _, _, _), .transitRoute(b, _, _, _)): return a == b
        case (.poi, .poi):
            return name == other.name
                && abs(latitude - other.latitude) < 0.0001
                && abs(longitude - other.longitude) < 0.0001
        case let (.journey(o1, d1), .journey(o2, d2)):
            return o1.matches(o2) && d1.matches(d2)
        default: return false
        }
    }

    var isJourney: Bool {
        if case .journey = kind { return true }
        return false
    }

    /// Places (not routes or journeys), as a directions end.
    var endpoint: DirectionsEndpoint? {
        switch kind {
        case .savedPlace, .stop, .poi: return DirectionsEndpoint(name: name, coordinate: coordinate)
        case .transitRoute, .journey: return nil
        }
    }

    /// The same entry, reopened now (moves it to the top).
    func refreshed(at now: Date = Date()) -> RecentSearch {
        var copy = self
        copy.date = now
        return copy
    }

    // MARK: - Builders

    static func journey(from origin: DirectionsEndpoint, to destination: DirectionsEndpoint) -> RecentSearch {
        let o = RecentEndpoint(origin), d = RecentEndpoint(destination)
        return RecentSearch(kind: .journey(origin: o, destination: d),
                            name: destination.name,
                            subtitle: "From \(origin.name)",
                            latitude: d.latitude, longitude: d.longitude)
    }

    // MARK: - List rules (pure)

    /// How many entries are kept.
    static let limit = 25

    /// `entry` goes first; an older copy of the same search is dropped and
    /// the list is trimmed to `limit`.
    static func inserting(_ entry: RecentSearch, into list: [RecentSearch],
                          limit: Int = limit) -> [RecentSearch] {
        var next = list.filter { !$0.isSameSearch(as: entry) }
        next.insert(entry, at: 0)
        return Array(next.prefix(limit))
    }
}
