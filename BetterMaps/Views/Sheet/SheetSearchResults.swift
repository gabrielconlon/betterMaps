import SwiftUI
import MapKit
import SwiftData

/// Search results inside the sheet: saved places, routes, stops and nearby
/// Apple Maps results, at most five per section with a "Show all" row.
struct SheetSearchResults: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteTransitRoute.sortOrder) private var favoriteRoutes: [FavoriteTransitRoute]

    let searchState: SearchState
    let onSelectPlace: (Place) -> Void
    let onSelectStop: (TransitStop) -> Void
    /// Draws the route on the map.
    let onSelectRoute: (TransitRoute) -> Void
    let onSelectPOI: (MKMapItem) -> Void

    static let sectionLimit = 5
    @State private var expanded: Set<SearchState.SearchSection> = []

    private var query: String { searchState.searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            if searchState.hasAnyResults {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(searchState.orderedSections, id: \.self) { section in
                        sectionView(section)
                    }
                }
            } else if searchState.isSearching {
                SkeletonRows(count: 4)
            } else {
                StatusView(status: .empty(title: "No matches for “\(query)”",
                                          hint: "Try a place name, stop number or route",
                                          systemImage: "magnifyingglass",
                                          action: nil))
            }
        }
        .onChange(of: query) { _, _ in expanded = [] }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: SearchState.SearchSection) -> some View {
        switch section {
        case .places:
            resultSection(section, title: "Saved places", items: searchState.placeSearchResults) { place in
                placeRow(place)
            }
        case .routes:
            resultSection(section, title: "Routes", items: searchState.routeSearchResults) { route in
                routeRow(route)
            }
        case .transitStops:
            resultSection(section, title: "Stops", items: searchState.transitSearchResults) { stop in
                stopRow(stop)
            }
        case .pois:
            resultSection(section, title: "Nearby", items: searchState.searchResults.map(POIItem.init)) { poi in
                poiRow(poi.item)
            }
        }
    }

    @ViewBuilder
    private func resultSection<Item: Identifiable, Row: View>(
        _ section: SearchState.SearchSection, title: String, items: [Item],
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if !items.isEmpty {
            let isExpanded = expanded.contains(section)
            VStack(alignment: .leading, spacing: 0) {
                SheetSectionHeader(title: title)
                ForEach(isExpanded ? items : Array(items.prefix(Self.sectionLimit))) { item in
                    row(item)
                    Divider().padding(.leading, 44)
                }
                if !isExpanded && items.count > Self.sectionLimit {
                    Button {
                        expanded.insert(section)
                    } label: {
                        Text("Show all \(items.count)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: - Rows

    private func placeRow(_ place: Place) -> some View {
        let color = (place.layers ?? []).first.flatMap { Color(hex: $0.colorHex) } ?? .gray
        let layerNames = (place.layers ?? []).map(\.name)
        return Button { onSelectPlace(place) } label: {
            SearchResultRow(icon: "mappin", iconColor: color, iconShape: .circle,
                            title: place.name,
                            subtitle: layerNames.isEmpty ? "Saved place" : layerNames.joined(separator: ", "))
        }
        .buttonStyle(.plain)
    }

    private func routeRow(_ route: TransitRoute) -> some View {
        let isFavorite = favoriteRoutes.contains { $0.routeId == route.id }
        return HStack(spacing: 0) {
            Button { onSelectRoute(route) } label: {
                SearchResultRow(icon: route.kind.systemImage, iconColor: TransitColors.pin(for: route),
                                iconShape: .rounded, title: "Route \(route.short)",
                                subtitle: route.long.isEmpty ? nil : route.long)
            }
            .buttonStyle(.plain)

            Button { toggleFavoriteRoute(route) } label: {
                Image(systemName: isFavorite ? "pin.fill" : "pin")
                    .foregroundStyle(isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Unpin route \(route.short)" : "Pin route \(route.short)")
        }
    }

    private func stopRow(_ stop: TransitStop) -> some View {
        Button { onSelectStop(stop) } label: {
            SearchResultRow(icon: stop.kind.systemImage, iconColor: TransitColors.pin(for: stop),
                            iconShape: .rounded, title: stop.name,
                            subtitle: stop.code.map { "\(stop.kind.displayName) · Stop \($0)" } ?? stop.kind.displayName)
        }
        .buttonStyle(.plain)
    }

    private func poiRow(_ item: MKMapItem) -> some View {
        Button { onSelectPOI(item) } label: {
            SearchResultRow(icon: "magnifyingglass", iconColor: .gray, iconShape: .circle,
                            title: item.name ?? "Unnamed place",
                            subtitle: [item.placemark.thoroughfare, item.placemark.locality]
                                .compactMap { $0 }.joined(separator: ", "))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pinned routes

    private func toggleFavoriteRoute(_ route: TransitRoute) {
        if let existing = favoriteRoutes.first(where: { $0.routeId == route.id }) {
            modelContext.delete(existing)
            return
        }
        let nextOrder = (favoriteRoutes.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(FavoriteTransitRoute(routeId: route.id, shortName: route.short,
                                                 longName: route.long, routeType: route.type,
                                                 sortOrder: nextOrder))
    }
}

/// `MKMapItem` is not `Identifiable`; wraps it by object identity.
private struct POIItem: Identifiable {
    let item: MKMapItem
    var id: ObjectIdentifier { ObjectIdentifier(item) }
}

/// Icon + title + subtitle, 52pt minimum.
struct SearchResultRow: View {
    enum IconShape { case circle, rounded }

    let icon: String
    let iconColor: Color
    let iconShape: IconShape
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(iconColor, in: iconShape == .circle
                            ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 7)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Small uppercase-free section title used across the sheet.
struct SheetSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
