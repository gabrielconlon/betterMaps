import SwiftUI
import SwiftData
import MapKit

/// What a search result tap should do on the map.
struct SheetSearchActions {
    let onSelectPlace: (Place) -> Void
    let onSelectStop: (TransitStop) -> Void
    let onSelectRoute: (TransitRoute) -> Void
    let onSelectPOI: (MKMapItem) -> Void
    /// The row's trailing arrow: plan a journey to this result.
    let onDirections: (DirectionsEndpoint) -> Void
}

/// Trail count and total length of one trail group, precomputed with the
/// screen's snapshot so the sheet never walks relationships in a body.
struct TrailGroupStats: Equatable, Sendable {
    var count: Int
    var meters: Double
}

/// Value lists the sheet's management sections render from.
struct SheetLayerLists: Equatable {
    /// Tags (place-kind layers) in sortOrder.
    var tags: [LayerLite] = []
    /// Trail groups (waypoint-path layers) in sortOrder.
    var trailGroups: [LayerLite] = []
    /// Places per tag id.
    var tagCounts: [UUID: Int] = [:]
    var trailStats: [UUID: TrailGroupStats] = [:]
}

/// Body of the persistent sheet at medium / expanded: search results while a
/// query is typed, otherwise hints, then pinned routes and stops first (the
/// things reached for on the way out the door), then tags and trail groups
/// to browse. Creating, editing and deleting tags and trail groups lives in
/// Settings and the "+" menu, so the sheet stays short. Nothing here changes
/// what the map shows; that is the layers panel's job.
struct LayersSheetContent: View {
    @Environment(\.modelContext) private var modelContext

    let lists: SheetLayerLists
    let placeCount: Int
    let viewModel: MapViewModel
    let searchState: SearchState
    let transitSettings: TransitLayerSettings
    let transitStore: TransitLayerStore
    let searchActions: SheetSearchActions
    /// Opens the trail editor; `nil` lets the screen pick or create the group.
    let onDrawTrail: (UUID?) -> Void

    @AppStorage(FirstRunHints.storageKey) private var hintsRaw = 0
    @State private var pendingDelete: LayerLite?

    private var isSearchActive: Bool {
        !searchState.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hints: Binding<FirstRunHints> {
        Binding(get: { FirstRunHints(rawValue: hintsRaw) }, set: { hintsRaw = $0.rawValue })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isSearchActive {
                    SheetSearchResults(searchState: searchState,
                                       onSelectPlace: searchActions.onSelectPlace,
                                       onSelectStop: searchActions.onSelectStop,
                                       onSelectRoute: searchActions.onSelectRoute,
                                       onSelectPOI: searchActions.onSelectPOI,
                                       onDirections: searchActions.onDirections)
                } else {
                    FirstRunHintsView(hints: hints)
                    PinnedRoutesSection(highlightedRouteId: transitStore.highlightedRouteId) { route in
                        transitStore.toggleHighlightedRoute(route.routeId, label: route.shortName)
                    }
                    PinnedStopsGroup(pinnedStopIds: transitSettings.pinnedStopIds) { stop in
                        viewModel.showTransitArrivals(for: stop)
                    }
                    tagsSection
                    if !lists.trailGroups.isEmpty { trailsSection }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: placeCount, initial: true) { _, _ in updateHints() }
        .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete,
                            titleVisibility: .visible, presenting: pendingDelete) { layer in
            Button(layer.kind == .waypointPath ? "Delete trail group" : "Delete tag", role: .destructive) {
                delete(layer)
            }
            Button("Cancel", role: .cancel) {}
        } message: { layer in
            Text(layer.kind == .waypointPath
                 ? "Its trails and their points are deleted too. This can't be undone."
                 : "Places with only this tag will be deleted. Places with other tags keep them. This can't be undone.")
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSectionHeader(title: "Tags")
            if lists.tags.isEmpty {
                StatusView(status: .empty(title: "No tags yet",
                                          hint: "Long-press the map to save your first place",
                                          action: nil))
            }
            ForEach(lists.tags) { tag in
                LayerCard(layer: tag,
                          subtitle: LayerCard.placeSummary(count: lists.tagCounts[tag.id] ?? 0),
                          onOpen: { viewModel.showLayerDetail(tag.id) })
                    .contextMenu { contextMenu(for: tag) }
                Divider().padding(.leading, 46)
            }
        }
    }

    // MARK: - Trails

    private var trailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSectionHeader(title: "Trails")
            ForEach(lists.trailGroups) { group in
                let stats = lists.trailStats[group.id] ?? TrailGroupStats(count: 0, meters: 0)
                LayerCard(layer: group,
                          subtitle: LayerCard.trailSummary(count: stats.count, meters: stats.meters),
                          onOpen: { viewModel.showLayerDetail(group.id) },
                          onDraw: { onDrawTrail(group.id) })
                    .contextMenu { contextMenu(for: group) }
                Divider().padding(.leading, 46)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for layer: LayerLite) -> some View {
        Button { viewModel.activeSheet = .editLayer(layer.id) } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button(role: .destructive) { pendingDelete = layer } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func delete(_ lite: LayerLite) {
        let id = lite.id
        var descriptor = FetchDescriptor<Layer>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let layer = try? modelContext.fetch(descriptor).first {
            PlaceCleanup.deleteLayer(layer, in: modelContext)
        }
    }

    private func updateHints() {
        var next = FirstRunHints(rawValue: hintsRaw)
        next.update(placeCount: placeCount, visibleLayerCount: lists.tags.count)
        if next.rawValue != hintsRaw { hintsRaw = next.rawValue }
    }

    private var deleteTitle: String {
        "Delete “\(pendingDelete?.name ?? "tag")”?"
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}
