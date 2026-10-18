import SwiftUI
import SwiftData

/// "Transit" section of the sheet: one card per network plus the bus
/// timetable status row.
struct TransitSheetSection: View {
    let transitSettings: TransitLayerSettings
    let timetable: BusTimetableModel
    /// A transit network was switched on or off.
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSectionHeader(title: "Transit")
            ForEach(TransitLayerKind.allCases) { kind in
                LayerCardRow(color: TransitColors.pin(kind),
                             symbol: kind.systemImage,
                             title: kind.displayName,
                             subtitle: Self.subtitle(kind),
                             isVisible: transitSettings.isEnabled(kind),
                             onToggle: {
                                 transitSettings.toggle(kind)
                                 onToggle()
                             })
            }
            BusTimetableStatusRow(model: timetable)
        }
    }

    static func subtitle(_ kind: TransitLayerKind) -> String {
        switch kind {
        case .bus: return "Stops appear as you zoom in"
        case .luas: return "Red and Green lines"
        case .dart: return "Coastal line"
        case .rail: return "Commuter and intercity"
        }
    }
}

/// Download / progress / last-updated line for the offline bus timetable.
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
                Text("Bus timetable")
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
        let color = Self.color(routeType: route.routeType)
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

    static func color(routeType: Int) -> Color {
        switch routeType {
        case 0: return TransitColors.luasGrnPin
        case 2: return TransitColors.dartPin
        default: return TransitColors.busPin
        }
    }
}
