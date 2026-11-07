import SwiftUI

/// "Recents" at the top of the sheet while the search field is empty:
/// places, routes and journeys opened from search, newest first. A tap
/// reopens one (a journey re-plans from now); the trailing arrow plans a
/// journey to a place; long-press removes one, and Clear empties the list.
struct RecentSearchesSection: View {
    let store: RecentSearchStore
    let onOpen: (RecentSearch) -> Void
    let onDirections: (DirectionsEndpoint) -> Void

    static let collapsedLimit = 5
    @State private var isExpanded = false
    @State private var isConfirmingClear = false

    var body: some View {
        if !store.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SheetSectionHeader(title: "Recents")
                    Button("Clear") { isConfirmingClear = true }
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Clear recent searches")
                }
                let shown = isExpanded ? store.items : Array(store.items.prefix(Self.collapsedLimit))
                ForEach(shown) { entry in
                    row(entry)
                    Divider().padding(.leading, 44)
                }
                if !isExpanded && store.items.count > Self.collapsedLimit {
                    Button { isExpanded = true } label: {
                        Text("Show all \(store.items.count)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .confirmationDialog("Clear recent searches?", isPresented: $isConfirmingClear,
                                titleVisibility: .visible) {
                Button("Clear recents", role: .destructive) {
                    store.clear()
                    isExpanded = false
                }
                Button("Cancel", role: .cancel) {}
            }
            .accessibilityIdentifier("sheet.recents")
        }
    }

    private func row(_ entry: RecentSearch) -> some View {
        let style = RecentSearchStyle(entry)
        return HStack(spacing: 0) {
            Button { onOpen(entry) } label: {
                SearchResultRow(icon: style.icon, iconColor: style.color, iconShape: style.shape,
                                title: entry.name, subtitle: entry.subtitle)
            }
            .buttonStyle(.plain)
            .accessibilityHint(entry.isJourney ? "Plans this journey again" : "")
            if let endpoint = entry.endpoint {
                Button { onDirections(endpoint) } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Directions to \(entry.name)")
            }
        }
        .contextMenu {
            Button(role: .destructive) { store.remove(entry.id) } label: {
                Label("Remove from Recents", systemImage: "trash")
            }
        }
        .accessibilityAction(named: "Remove from Recents") { store.remove(entry.id) }
    }
}

/// Icon, colour and shape for a recent entry, matching the search result
/// row it came from.
struct RecentSearchStyle {
    let icon: String
    let color: Color
    let shape: SearchResultRow.IconShape

    init(_ entry: RecentSearch) {
        switch entry.kind {
        case .savedPlace(_, let hex):
            icon = "mappin"; color = hex.flatMap { Color(hex: $0) } ?? .gray; shape = .circle
        case .stop(_, let kind, let line, _):
            icon = kind.systemImage; color = TransitColors.pin(kind, line: line); shape = .rounded
        case .poi:
            icon = "mappin.and.ellipse"; color = .gray; shape = .circle
        case .transitRoute(_, let short, _, let type):
            let route = TransitRoute(id: "", short: short, long: "", type: type)
            icon = route.kind.systemImage; color = TransitColors.pin(for: route); shape = .rounded
        case .journey:
            icon = "arrow.triangle.turn.up.right.diamond.fill"; color = .accentColor; shape = .circle
        }
    }
}
