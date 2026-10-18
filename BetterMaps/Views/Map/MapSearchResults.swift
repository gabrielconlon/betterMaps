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
    /// Draws the route on the map.
    let onSelectRoute: (TransitRoute) -> Void
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
        ForEach(searchState.routeSearchResults) { route in
            HStack(spacing: 10) {
                Button(action: { onSelectRoute(route) }) {
                    HStack(spacing: 10) {
                        Image(systemName: route.type == 0 ? "tram.fill" : (route.type == 2 ? "train.side.front.car" : "bus.fill"))
                            .foregroundStyle(.white)
                            .font(.caption.bold())
                            .frame(width: 28, height: 28)
                            .background(TransitColors.pin(route.kind))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Route \(route.short)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            if !route.long.isEmpty {
                                Text(route.long)
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
                    Image(systemName: isRouteFavorited(route.id) ? "star.fill" : "star")
                        .font(.subheadline)
                        .foregroundStyle(isRouteFavorited(route.id) ? .yellow : .secondary)
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
                    Image(systemName: stop.kind.systemImage)
                        .foregroundStyle(.white)
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(TransitColors.pin(for: stop))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(stop.code.map { "\(stop.kind.displayName) · Stop \($0)" } ?? stop.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(TransitColors.pin(for: stop))
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

    private func toggleFavoriteRoute(_ route: TransitRoute) {
        if let existing = favoriteRoutes.first(where: { $0.routeId == route.id }) {
            modelContext.delete(existing)
            return
        }
        let nextOrder = (favoriteRoutes.map(\.sortOrder).max() ?? -1) + 1
        let fav = FavoriteTransitRoute(
            routeId: route.id,
            shortName: route.short,
            longName: route.long,
            routeType: route.type,
            sortOrder: nextOrder
        )
        modelContext.insert(fav)
    }
}
