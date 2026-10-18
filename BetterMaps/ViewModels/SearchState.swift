import SwiftUI
import MapKit
import Observation

@Observable
@MainActor
class SearchState {
    var searchText: String = ""
    var searchResults: [MKMapItem] = []
    var placeSearchResults: [Place] = []
    var transitSearchResults: [TransitStop] = []
    var routeSearchResults: [TransitRoute] = []
    var showSearchResults: Bool = false

    /// Cancellable task for debounced live search
    private var liveSearchTask: Task<Void, Never>?

    // MARK: - Search Section Ordering (Serial Position Effect)

    enum SearchSection: CaseIterable {
        case places, routes, transitStops, pois
    }

    var orderedSections: [SearchSection] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        // Route number pattern: digits optionally followed by 1-2 letters (39A, 145, 15B, C1)
        let isRouteNumber = trimmed.range(of: #"^\d+[A-Za-z]{0,2}$"#, options: .regularExpression) != nil
        // Known transit keywords
        let transitKeywords = ["dart", "luas", "green line", "red line"]
        let isTransitKeyword = transitKeywords.contains(where: { lower.contains($0) })

        if isRouteNumber || isTransitKeyword {
            return [.routes, .transitStops, .places, .pois]
        }

        // Exact saved place name match
        if placeSearchResults.contains(where: { $0.name.lowercased() == lower }) {
            return [.places, .routes, .transitStops, .pois]
        }

        // Default order
        return [.places, .routes, .transitStops, .pois]
    }

    // MARK: - Search

    func performSearch(places: [Place], transit: TransitLayerStore, userLocation: CLLocationCoordinate2D?) async {
        guard !searchText.isEmpty else { return }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let words = query.lowercased().split(separator: " ").map(String.init)

        // Search saved places (instant, in-memory)
        placeSearchResults = places
            .filter { place in
                words.allSatisfy { word in
                    place.name.localizedCaseInsensitiveContains(word) ||
                    place.tags.contains { $0.localizedCaseInsensitiveContains(word) } ||
                    place.notes.localizedCaseInsensitiveContains(word)
                }
            }
            .sorted { a, b in
                let firstWord = words.first ?? query.lowercased()
                let aPrefix = a.name.lowercased().hasPrefix(firstWord)
                let bPrefix = b.name.lowercased().hasPrefix(firstWord)
                if aPrefix != bPrefix { return aPrefix }
                return a.name < b.name
            }

        // Transit stops and routes come from the bundled JSON (in memory).
        // Typing a search is an explicit request, so it may trigger the
        // one-off decode even when no transit layer is switched on.
        await transit.loadIfNeeded()
        guard !Task.isCancelled else { return }
        transitSearchResults = Self.searchStops(transit.stops, query: query)
        routeSearchResults = Self.searchRoutes(transit.routes, query: query)

        // Search Apple Maps POIs (network call)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let userLocation {
            request.region = MKCoordinateRegion(
                center: userLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            searchResults = response.mapItems
        }
        showSearchResults = true
    }

    // MARK: - Debounced Live Search

    /// Call on every keystroke — debounces 300ms then runs performSearch.
    func debouncedSearch(places: [Place], transit: TransitLayerStore, userLocation: CLLocationCoordinate2D?) {
        liveSearchTask?.cancel()
        let text = searchText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            showSearchResults = false
            return
        }
        liveSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(places: places, transit: transit, userLocation: userLocation)
        }
    }

    // MARK: - Transit matching (pure)

    /// Stops whose name contains every word, or whose plate code starts
    /// with the query; name-prefix matches first.
    nonisolated static func searchStops(_ stops: [TransitStop], query: String, limit: Int = 20) -> [TransitStop] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let words = trimmed.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return [] }
        let matches = stops.filter { stop in
            if let code = stop.code, code.hasPrefix(trimmed) { return true }
            let name = stop.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        return Array(matches.sorted { a, b in
            let aCode = a.code == trimmed, bCode = b.code == trimmed
            if aCode != bCode { return aCode }
            let aPrefix = a.name.lowercased().hasPrefix(first)
            let bPrefix = b.name.lowercased().hasPrefix(first)
            if aPrefix != bPrefix { return aPrefix }
            return a.name < b.name
        }.prefix(limit))
    }

    /// Routes whose short name starts with the query, or whose long name
    /// contains every word; exact short-name matches first.
    nonisolated static func searchRoutes(_ routes: [TransitRoute], query: String, limit: Int = 10) -> [TransitRoute] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let words = trimmed.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = routes.filter { route in
            route.short.lowercased().hasPrefix(trimmed.lowercased())
                || words.allSatisfy { route.long.lowercased().contains($0) }
        }
        return Array(matches.sorted { a, b in
            let aExact = a.short.caseInsensitiveCompare(trimmed) == .orderedSame
            let bExact = b.short.caseInsensitiveCompare(trimmed) == .orderedSame
            if aExact != bExact { return aExact }
            return a.short.localizedStandardCompare(b.short) == .orderedAscending
        }.prefix(limit))
    }

    // MARK: - Clear

    func clearSearch() {
        searchText = ""
        searchResults = []
        placeSearchResults = []
        transitSearchResults = []
        routeSearchResults = []
        showSearchResults = false
    }
}
