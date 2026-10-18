import SwiftUI
import SwiftData
import MapKit

/// What a search result tap should do on the map.
struct SheetSearchActions {
    let onSelectPlace: (Place) -> Void
    let onSelectStop: (TransitStop) -> Void
    let onSelectRoute: (TransitRoute) -> Void
    let onSelectPOI: (MKMapItem) -> Void
}

/// Body of the persistent sheet at medium / expanded: search results while a
/// query is typed, otherwise hints, your layers, filter mode, transit,
/// pinned routes and "+ New layer" last.
struct LayersSheetContent: View {
    @Environment(\.modelContext) private var modelContext

    /// User layers in sortOrder.
    let layers: [Layer]
    let placeCount: Int
    let viewModel: MapViewModel
    @Bindable var filterVM: LayerFilterViewModel
    let searchState: SearchState
    let transitSettings: TransitLayerSettings
    let transitStore: TransitLayerStore
    let timetable: BusTimetableModel
    let searchActions: SheetSearchActions

    @AppStorage(FirstRunHints.storageKey) private var hintsRaw = 0
    @State private var layerPendingDelete: Layer?

    private var isSearchActive: Bool {
        !searchState.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var visiblePlaceLayerCount: Int {
        layers.filter { $0.isVisible && $0.kind == .places }.count
    }

    private var visibleLayerCount: Int { layers.filter(\.isVisible).count }

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
                                       onSelectPOI: searchActions.onSelectPOI)
                } else {
                    FirstRunHintsView(hints: hints)
                    layersSection
                    TransitSheetSection(transitSettings: transitSettings, timetable: timetable,
                                        onToggle: markToggled)
                    PinnedRoutesSection(highlightedRouteId: transitStore.highlightedRouteId) { route in
                        transitStore.toggleHighlightedRoute(route.routeId)
                    }
                    newLayerRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: placeCount, initial: true) { _, _ in updateHints() }
        .onChange(of: visibleLayerCount, initial: true) { _, _ in updateHints() }
        .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete,
                            titleVisibility: .visible, presenting: layerPendingDelete) { layer in
            Button("Delete layer", role: .destructive) { modelContext.delete(layer) }
            Button("Cancel", role: .cancel) {}
        } message: { layer in
            Text(layer.kind == .waypointPath
                 ? "Its trails are deleted too. This can't be undone."
                 : "Places in it stay saved in your other layers.")
        }
    }

    // MARK: - Your layers

    @ViewBuilder
    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSectionHeader(title: "Your layers")
            if layers.isEmpty {
                StatusView(status: .empty(title: "No layers yet",
                                          hint: "Long-press the map to save your first place",
                                          action: nil))
            } else {
                ForEach(layers) { layer in
                    LayerCard(layer: layer,
                              onOpen: { viewModel.showLayerDetail(layer.id) },
                              onToggle: {
                                  layer.isVisible.toggle()
                                  markToggled()
                              },
                              onDraw: { viewModel.requestDrawTrail(in: layer.id) })
                    .contextMenu { contextMenu(for: layer) }
                    if layer.id != layers.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            if visiblePlaceLayerCount >= 2 {
                filterControl.padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for layer: Layer) -> some View {
        Button { viewModel.activeSheet = .editLayer(layer.id) } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button { showOnly(layer) } label: {
            Label("Show only this layer", systemImage: "eye")
        }
        Button(role: .destructive) { layerPendingDelete = layer } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var filterControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Show places in", selection: $filterVM.filterMode) {
                Text("Any layer").tag(FilterMode.union)
                Text("All layers").tag(FilterMode.intersection)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            if filterVM.filterMode == .intersection {
                Text("Showing places in every visible layer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var newLayerRow: some View {
        Button { viewModel.activeSheet = .newLayer } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text("New layer")
                    .font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func showOnly(_ target: Layer) {
        for layer in layers { layer.isVisible = layer.id == target.id }
        markToggled()
    }

    private func markToggled() {
        hints.wrappedValue.markDone(.toggleLayer)
    }

    private func updateHints() {
        var next = FirstRunHints(rawValue: hintsRaw)
        next.update(placeCount: placeCount, visibleLayerCount: visibleLayerCount)
        if next.rawValue != hintsRaw { hintsRaw = next.rawValue }
    }

    private var deleteTitle: String {
        "Delete “\(layerPendingDelete?.name ?? "layer")”?"
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { layerPendingDelete != nil }, set: { if !$0 { layerPendingDelete = nil } })
    }
}
