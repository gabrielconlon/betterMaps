import SwiftUI
import MapKit
import SwiftData

/// The search-results list that floats above the bottom bar. Moved out of
/// MapTabView unchanged; Phase 5 replaces this chrome.
struct MapSearchResults: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteTransitRoute.sortOrder) private var favoriteRoutes: [FavoriteTransitRoute]

    let searchState: SearchState
    let onSelectPlace: (Place) -> Void
    let onSelectStop: (TransitStop) -> Void
    let onSelectPOI: (MKMapItem) -> Void

    var hasResults: Bool {
        searchState.showSearchResults && (!searchState.placeSearchResults.isEmpty
            || !searchState.transitSearchResults.isEmpty
            || !searchState.routeSearchResults.isEmpty
            || !searchState.searchResults.isEmpty)
    }

    var body: some View {
        if hasResults {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(searchState.orderedSections, id: \.self) { section in
                        switch section {
                        case .places: savedPlaceResults
                        case .routes: routeResults
                        case .transitStops: transitStopResults
                        case .pois: poiResults
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var savedPlaceResults: some View {
        ForEach(searchState.placeSearchResults.prefix(5)) { place in
            Button(action: { onSelectPlace(place) }) {
                HStack(spacing: 10) {
                    ZStack {
                        let layerColors = (place.layers ?? []).prefix(2).compactMap { Color(hex: $0.colorHex) }
                        Circle().fill(layerColors.first ?? .gray.opacity(0.3)).frame(width: 28, height: 28)
                        Image(systemName: "mappin")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        let layerNames = (place.layers ?? []).map(\.name)
                        Text(layerNames.isEmpty ? "Saved place" : layerNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Saved")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var routeResults: some View {
        ForEach(searchState.routeSearchResults, id: \.routeId) { route in
            HStack(spacing: 10) {
                Button(action: {
                    // Route drawing was removed with the planner; phase 2
                    // rewires this. For now a tap just clears the search.
                    searchState.showSearchResults = false
                    searchState.searchText = ""
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: route.routeType == 0 ? "tram.fill" : (route.routeType == 2 ? "train.side.front.car" : "bus.fill"))
                            .foregroundStyle(.white)
                            .font(.caption.bold())
                            .frame(width: 28, height: 28)
                            .background(route.routeType == 0 ? .green : (route.routeType == 2 ? .orange : .blue))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Route \(route.routeName)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            if !route.longName.isEmpty {
                                Text(route.longName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "map.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Star toggle — pin/unpin this route to the layers panel quick-access strip.
                Button(action: { toggleFavoriteRoute(route) }) {
                    Image(systemName: isRouteFavorited(route.routeId) ? "star.fill" : "star")
                        .font(.subheadline)
                        .foregroundStyle(isRouteFavorited(route.routeId) ? .yellow : .secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
        }
    }

    @ViewBuilder
    private var transitStopResults: some View {
        ForEach(searchState.transitSearchResults.prefix(5)) { stop in
            Button(action: { onSelectStop(stop) }) {
                HStack(spacing: 10) {
                    Image(systemName: stop.type.systemImage)
                        .foregroundStyle(.white)
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(Color(hex: stop.type.colorHex) ?? .blue)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(stop.type.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(Color(hex: stop.type.colorHex) ?? .blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var poiResults: some View {
        // Separator before Apple Maps results
        if (!searchState.placeSearchResults.isEmpty || !searchState.transitSearchResults.isEmpty || !searchState.routeSearchResults.isEmpty) && !searchState.searchResults.isEmpty {
            Text("Nearby")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
        }

        ForEach(searchState.searchResults, id: \.self) { item in
            Button(action: { onSelectPOI(item) }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Unknown")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text([item.placemark.thoroughfare, item.placemark.locality]
                            .compactMap { $0 }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
    }

    // MARK: - Favorite routes

    private func isRouteFavorited(_ routeId: String) -> Bool {
        favoriteRoutes.contains { $0.routeId == routeId }
    }

    private func toggleFavoriteRoute(_ route: (routeId: String, routeName: String, longName: String, routeType: Int)) {
        if let existing = favoriteRoutes.first(where: { $0.routeId == route.routeId }) {
            modelContext.delete(existing)
            return
        }
        let nextOrder = (favoriteRoutes.map(\.sortOrder).max() ?? -1) + 1
        let fav = FavoriteTransitRoute(
            routeId: route.routeId,
            shortName: route.routeName,
            longName: route.longName,
            routeType: route.routeType,
            sortOrder: nextOrder
        )
        modelContext.insert(fav)
    }
}
