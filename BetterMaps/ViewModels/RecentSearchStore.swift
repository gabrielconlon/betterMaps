import Foundation
import MapKit
import Observation

/// Places, transit routes and journeys the user searched for, newest first.
///
/// Kept on this device in UserDefaults (`recentSearches`, a JSON array of
/// `RecentSearch`), like the tag filter and the trail draft, not in the
/// SwiftData store: a search history is personal to the device, and a new
/// CloudKit record type would first have to be deployed to the Production
/// schema before any build could ship with it.
@Observable
@MainActor
final class RecentSearchStore {
    static let shared = RecentSearchStore()
    nonisolated static let storageKey = "recentSearches"

    private(set) var items: [RecentSearch]

    /// Places only (saved places, stops, Apple Maps results), for the
    /// directions endpoint picker.
    var places: [RecentSearch] { items.filter { $0.endpoint != nil } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = Self.read(from: defaults)
    }

    // MARK: - Recording

    func record(_ entry: RecentSearch) {
        items = RecentSearch.inserting(entry, into: items)
        persist()
    }

    func recordPlace(_ place: Place) {
        let tags = place.layers ?? []
        let subtitle = tags.isEmpty ? "Saved place" : tags.map(\.name).joined(separator: ", ")
        record(RecentSearch(kind: .savedPlace(id: place.id, tagColorHex: tags.first?.colorHex),
                            name: place.name, subtitle: subtitle,
                            latitude: place.latitude, longitude: place.longitude))
    }

    func recordStop(_ stop: TransitStop) {
        let subtitle = stop.code.map { "\(stop.kind.displayName) · Stop \($0)" } ?? stop.kind.displayName
        record(RecentSearch(kind: .stop(id: stop.id, kind: stop.kind, line: stop.line, code: stop.code),
                            name: stop.name, subtitle: subtitle,
                            latitude: stop.latitude, longitude: stop.longitude))
    }

    func recordRoute(_ route: TransitRoute) {
        record(RecentSearch(kind: .transitRoute(id: route.id, short: route.short, long: route.long, type: route.type),
                            name: "Route \(route.short)", subtitle: route.long.isEmpty ? nil : route.long,
                            latitude: 0, longitude: 0))
    }

    func recordPOI(_ item: MKMapItem) {
        let pm = item.placemark
        let subtitle = [pm.thoroughfare, pm.locality].compactMap { $0 }.joined(separator: ", ")
        record(RecentSearch(kind: .poi, name: item.name ?? "Unnamed place",
                            subtitle: subtitle.isEmpty ? nil : subtitle,
                            latitude: pm.coordinate.latitude, longitude: pm.coordinate.longitude))
    }

    func recordJourney(from origin: DirectionsEndpoint, to destination: DirectionsEndpoint) {
        record(.journey(from: origin, to: destination))
    }

    // MARK: - Removing

    func remove(_ id: RecentSearch.ID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items = []
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Storage

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    nonisolated static func read(from defaults: UserDefaults) -> [RecentSearch] {
        guard let data = defaults.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([RecentSearch].self, from: data) else { return [] }
        return items
    }
}
