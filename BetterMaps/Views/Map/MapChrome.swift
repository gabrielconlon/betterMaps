import SwiftUI

// Bottom bar and layers-panel overlay, moved out of MapTabView unchanged.
// Phase 5 replaces this chrome.

/// [settings] [search capsule] [overlap toggle]
struct MapBottomBar: View {
    @Bindable var searchState: SearchState
    @Bindable var filterVM: LayerFilterViewModel
    var isSearchFocused: FocusState<Bool>.Binding
    let activeLayerCount: Int
    let onOpenMenu: () -> Void
    let onSearchTextChanged: () -> Void

    private var isOverlapMode: Bool {
        filterVM.filterMode == .intersection && activeLayerCount > 1
    }

    var body: some View {
        HStack(spacing: 10) {
            // Settings (full hamburger menu)
            Button(action: onOpenMenu) {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // Search field — floating style
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search stops, routes, places...", text: $searchState.searchText)
                    .textFieldStyle(.plain)
                    .focused(isSearchFocused)
                    .onChange(of: searchState.searchText) { _, _ in onSearchTextChanged() }
                    .onSubmit { isSearchFocused.wrappedValue = false }
                if !searchState.searchText.isEmpty {
                    Button(action: {
                        searchState.clearSearch()
                        isSearchFocused.wrappedValue = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                // Tap catcher — only when TextField is NOT focused.
                // Catches the first tap before the map's gesture recognizer can steal it.
                // Color.clear (not Capsule().fill(.clear)) — a clear-filled shape can fail
                // hit testing even with .contentShape; Color.clear is always hit-testable.
                if !isSearchFocused.wrappedValue {
                    Color.clear
                        .contentShape(Capsule())
                        .onTapGesture { isSearchFocused.wrappedValue = true }
                }
            }

            // Overlap toggle — only visible when 2+ layers active
            if activeLayerCount > 1 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        filterVM.filterMode = filterVM.filterMode == .union ? .intersection : .union
                    }
                }) {
                    Image(systemName: isOverlapMode ? "circle.grid.cross.fill" : "square.grid.2x2")
                        .font(.body)
                        .padding(10)
                        .background(isOverlapMode
                            ? AnyShapeStyle(Color.purple.opacity(0.2))
                            : AnyShapeStyle(.ultraThinMaterial))
                        .foregroundStyle(isOverlapMode ? .purple : .primary)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Top-left layers button, the FavoritesPanel it opens, and the legend strip
/// shown beneath the button while the panel is closed.
struct MapLayersOverlay: View {
    @Binding var showFavoritesPanel: Bool
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var mapStyleOption: MapStyleOption
    let legendLayers: [LayerLite]
    let legendEntries: [LegendEntry]

    /// Reserve enough vertical room for the bottom bar (search field + buttons).
    /// 56pt button stack + 8pt bottom padding + ~12pt buffer above the search bar.
    private static let panelBottomReserve: CGFloat = 76

    var body: some View {
        // ZStack must claim the full screen so its alignment(.topLeading) actually
        // pins the toggle button to the corner. The dimmer view (only shown when
        // the panel is open) is what catches outside taps to dismiss.
        ZStack(alignment: .topLeading) {
            if showFavoritesPanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                VStack(alignment: .leading, spacing: 8) {
                    toggleButton
                    FavoritesPanel(
                        showTransitStops: $showTransitStops,
                        isPresented: $showFavoritesPanel,
                        mapStyle: $mapStyleOption,
                        onSelectRoute: { _ in
                            // Route drawing was removed with the planner; the
                            // chip just closes the panel until phase 2 rewires it.
                            close()
                        }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                .padding(.leading, 12)
                .padding(.top, 10)
                .padding(.bottom, Self.panelBottomReserve)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    toggleButton
                    LegendStrip(layers: legendLayers, entries: legendEntries)
                }
                .padding(.leading, 12)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(10)
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.25)) { showFavoritesPanel = false }
    }

    private var toggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.25)) { showFavoritesPanel.toggle() }
        }) {
            Image(systemName: "square.3.layers.3d")
                .font(.body)
                .padding(10)
                .background {
                    if showFavoritesPanel {
                        Circle().fill(Color.blue.opacity(0.2))
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .foregroundStyle(showFavoritesPanel ? .blue : .primary)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.1), radius: 2)
        }
    }
}
