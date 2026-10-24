import SwiftUI
import SwiftData

/// "Transit" section of the sheet: pinned stops and the bus timetable
/// status row. The networks themselves are switched in the layers panel.
struct TransitSheetSection: View {
    let transitSettings: TransitLayerSettings
    let timetable: BusTimetableModel
    /// Opens a stop's arrivals (the host routes it, e.g.
    /// `viewModel.showTransitArrivals`). The "Pinned stops" group only
    /// shows when this is set.
    var onOpenStop: ((TransitStop) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onOpenStop {
                PinnedStopsGroup(pinnedStopIds: transitSettings.pinnedStopIds, onOpen: onOpenStop)
            }
            SheetSectionHeader(title: "Transit")
            BusTimetableStatusRow(model: timetable)
        }
    }
}

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

/// Download / progress / last-updated line for the offline timetable.
struct BusTimetableStatusRow: View {
    let model: BusTimetableModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Timetable")
                    .font(.subheadline)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if case .downloading(let fraction) = model.state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 160)
                }
            }
            Spacer(minLength: 0)
            switch model.state {
            case .notDownloaded:
                actionButton("Download") { model.download() }
            case .failed:
                actionButton("Try again") { model.download() }
            default:
                EmptyView()
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .task { await model.refresh() }
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var icon: String {
        switch model.state {
        case .ready: return "clock.badge.checkmark"
        case .failed: return "exclamationmark.triangle"
        default: return "clock.arrow.circlepath"
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
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
