import SwiftUI
import SwiftData

/// Stops the user starred in an arrivals sheet, in the order they were
/// pinned. Tap opens the stop's arrivals. Hidden when nothing is pinned or
/// none of the ids resolve against the bundled stop list.
struct PinnedStopsGroup: View {
    let pinnedStopIds: [String]
    let onOpen: (TransitStop) -> Void
    private let store = TransitLayerStore.shared

    var body: some View {
        let stops = Self.resolve(pinnedStopIds, using: store.stop(id:))
        VStack(alignment: .leading, spacing: 0) {
            if !stops.isEmpty {
                SheetSectionHeader(title: "Pinned stops")
                ForEach(stops) { stop in
                    Button { onOpen(stop) } label: {
                        SearchResultRow(icon: stop.kind.systemImage,
                                        iconColor: TransitColors.pin(for: stop),
                                        iconShape: .circle,
                                        title: stop.name,
                                        subtitle: Self.subtitle(stop))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows departures")
                }
            }
        }
        .padding(.bottom, stops.isEmpty ? 0 : 12)
        // Stop names live in the bundled JSON, which is only decoded once a
        // network is switched on; decode it here when there are pins to show.
        .task(id: pinnedStopIds.isEmpty) {
            guard !pinnedStopIds.isEmpty else { return }
            await store.loadIfNeeded()
        }
    }

    /// Pinned ids → stops, in pin order, skipping unknown ids and repeats
    /// (an alt id and its main id resolve to the same stop).
    nonisolated static func resolve(_ ids: [String], using lookup: (String) -> TransitStop?) -> [TransitStop] {
        var seen = Set<String>()
        return ids.compactMap(lookup).filter { seen.insert($0.id).inserted }
    }

    nonisolated static func subtitle(_ stop: TransitStop) -> String {
        let networks = stop.kinds.map(\.displayName).joined(separator: " · ")
        guard let code = stop.code else { return networks }
        return "\(networks) · Stop \(code)"
    }
}

/// Horizontally scrolling chips for routes the user pinned from search. Tap
/// draws the route on the map; long-press to unpin.
struct PinnedRoutesSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteTransitRoute.sortOrder) private var routes: [FavoriteTransitRoute]
    let highlightedRouteId: String?
    let onSelect: (FavoriteTransitRoute) -> Void

    var body: some View {
        if !routes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SheetSectionHeader(title: "Pinned routes")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(routes) { route in chip(route) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func chip(_ route: FavoriteTransitRoute) -> some View {
        let isOn = highlightedRouteId == route.routeId
        let color = TransitColors.pin(routeType: route.routeType, shortName: route.shortName)
        return Button { onSelect(route) } label: {
            Text(route.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? .white : .primary)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 36)
                .background(isOn ? color : color.opacity(0.22), in: Capsule())
                .overlay { Capsule().strokeBorder(color, lineWidth: isOn ? 0 : 1) }
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Route \(route.shortName)")
        .accessibilityValue(isOn ? "Shown on map" : "Hidden")
        .contextMenu {
            if !route.longName.isEmpty { Text(route.longName) }
            Button(role: .destructive) { modelContext.delete(route) } label: {
                Label("Unpin route", systemImage: "pin.slash")
            }
        }
    }

}
