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
    var routeSearchResults: [(routeId: String, routeName: String, longName: String, routeType: Int)] = []
    var showSearchResults: Bool = false

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

    func performSearch(places: [Place], transitStops: [TransitStop], userLocation: CLLocationCoordinate2D?) async {
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

        // Search transit stops by name (instant, in-memory)
        transitSearchResults = transitStops
            .filter { stop in
                words.allSatisfy { word in stop.name.lowercased().contains(word) }
            }
            .sorted { a, b in
                let firstWord = words.first ?? query.lowercased()
                let aPrefix = a.name.lowercased().hasPrefix(firstWord)
                let bPrefix = b.name.lowercased().hasPrefix(firstWord)
                if aPrefix != bPrefix { return aPrefix }
                return a.name < b.name
            }

        // Search GTFS routes by name/number (instant, from SQLite)
        let rawResults = await GTFSScheduleService.shared.searchRoutes(query: words.first ?? query)
        routeSearchResults = rawResults.filter { route in
            words.allSatisfy { word in
                route.routeName.localizedCaseInsensitiveContains(word) ||
                route.longName.localizedCaseInsensitiveContains(word)
            }
        }

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
