import SwiftUI
import MapKit
import SwiftData

/// The map screen: owns the SwiftData queries, view models and the
/// `MapContentStore`, routes sheets, and composes `MapCanvas`, the map
/// chrome and the persistent layers sheet. Everything the `Map` draws comes
/// from `store.output` or value arrays — SwiftData objects never reach the
/// map content.
struct MapScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var layers: [Layer]
    @Query private var places: [Place]

    @State private var viewModel = MapViewModel()
    @State private var filterVM = LayerFilterViewModel()
    @State private var locationManager = LocationManager()
    @State private var store = MapContentStore(region: Self.launchRegion)
    @State private var trailSnapshotter = TrailSnapshotter()
    @State private var toastCenter = ToastCenter()
    @State private var timetable = BusTimetableModel()
    @Namespace private var mapScope

    /// Default to a fixed Dublin region rather than `.userLocation(fallback:)`.
    /// `.userLocation` triggers continuous CoreLocation requests on every
    /// body recompute, which under load was hitting the kernel's 24k/sec rate
    /// limit and leaving MapKit's CAMetalLayer stuck at 0×0 (white-screen
    /// hang). The location button still recenters on demand.
    private static let launchRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var cameraPosition: MapCameraPosition = .region(Self.launchRegion)
    @State private var transitStore = TransitLayerStore.shared
    @State private var transitSettings = TransitLayerSettings.shared
    @State private var searchState = SearchState()
    @FocusState private var isSearchFocused: Bool
    @AppStorage(MapStyleOption.storageKey) private var mapStyleOption: MapStyleOption = .standard
    @State private var sheetDetent: SheetDetent = Self.initialDetent
    /// Settled sheet height above the bottom safe area; toasts sit on top of it.
    @State private var sheetHeight: CGFloat = SheetLayout.collapsedContentHeight
    @State private var poiSearchTask: Task<Void, Never>?

    private static var initialDetent: SheetDetent {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sheetMedium") { return .medium }
        #endif
        return .collapsed
    }

    // MARK: - Snapshots

    /// Value snapshot of the SwiftData graph. Reading it in `body` is what
    /// makes the screen re-feed the store when a place or layer changes.
    private struct Snapshot: Equatable {
        var places: [PlaceLite]
        var layers: [LayerLite]
    }

    private var snapshot: Snapshot {
        Snapshot(places: places.map(PlaceLite.init), layers: layers.map(LayerLite.init))
    }

    private var layersById: [UUID: LayerLite] {
        Dictionary(layers.map { (LayerLite($0).id, LayerLite($0)) }, uniquingKeysWith: { first, _ in first })
    }

    private var sortedLayers: [Layer] {
        layers.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var visibleLayerLites: [LayerLite] {
        sortedLayers.filter(\.isVisible).map(LayerLite.init)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            MapCanvas(
                cameraPosition: $cameraPosition,
                store: store,
                layersById: layersById,
                mapStyle: mapStyleOption.mapStyle,
                mapScope: mapScope,
                transit: TransitLayerContent.Inputs(transitStore),
                onTapPlace: { id in
                    if let place = places.first(where: { $0.id == id }) { viewModel.selectPlace(place) }
                },
                onTapCluster: zoom(to:),
                onTapStop: { stop in viewModel.showTransitArrivals(for: stop) },
                onTap: handleTap,
                onLongPress: handleLongPress,
                onCameraSettled: { region in
                    transitStore.region = region
                    if isSearchFocused { isSearchFocused = false }
                }
            )
            .ignoresSafeArea(.keyboard)

            MapChrome(mapScope: mapScope,
                      mapStyle: mapStyleOption,
                      legendLayers: visibleLayerLites,
                      legendEntries: store.output.legend,
                      isHidden: sheetDetent == .expanded,
                      onCycleMapStyle: cycleMapStyle)

            BottomSheet(detent: $sheetDetent,
                        onSettledHeightChange: { sheetHeight = $0 },
                        header: { sheetHeader },
                        content: { sheetContent })

            // Toast host: clear and untouchable itself, its toast sits just
            // above the sheet.
            Color.clear
                .allowsHitTesting(false)
                .toasts(toastCenter)
                .padding(.bottom, sheetHeight)
        }
        .mapScope(mapScope)
        .environment(toastCenter)
        .environment(\.mapCenter, transitStore.region.center)
        .onAppear { locationManager.requestPermission() }
        .onChange(of: snapshot, initial: true) { _, new in feedStore(new) }
        .onChange(of: filterVM.filterMode, initial: true) { _, mode in store.filterMode = mode }
        .onChange(of: transitSettings.enabledKinds, initial: true) { _, kinds in
            transitStore.enabledKinds = kinds
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { sheetDetent = .expanded }
        }
        .onChange(of: sheetDetent) { _, detent in
            if detent == .collapsed, isSearchFocused { isSearchFocused = false }
        }
        // Transit data is decoded only once a transit layer is on; a user
        // with every transit kind off does no transit work at launch.
        .task(id: transitSettings.enabledKinds.isEmpty) {
            guard !transitSettings.enabledKinds.isEmpty else { return }
            await transitStore.loadIfNeeded()
            await BusTimetableService.shared.refreshIfStale(days: 14)
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(for: sheet)
                .environment(toastCenter)
                .environment(\.mapCenter, transitStore.region.center)
        }
        // TRAIL HOOK: swap DrawTrailPlaceholder for the trail editor.
        .fullScreenCover(item: $viewModel.drawTrailRequest) { request in
            DrawTrailPlaceholder(request: request)
                .environment(toastCenter)
        }
    }

    // MARK: - Sheet

    private var sheetHeader: some View {
        LayersSheetHeader(
            layers: sortedLayers,
            searchState: searchState,
            isSearchFocused: $isSearchFocused,
            detent: sheetDetent,
            transitSettings: transitSettings,
            onSearchTextChanged: {
                searchState.debouncedSearch(places: places, transit: transitStore,
                                            userLocation: locationManager.userLocation)
            },
            onCancelSearch: {
                dismissSearch()
                sheetDetent = .collapsed
            },
            onAddPlace: { viewModel.startNewPlace(at: nil) },
            onDrawTrail: { viewModel.requestDrawTrail(in: nil) },
            onNewLayer: { viewModel.activeSheet = .newLayer },
            onOpenSettings: { viewModel.activeSheet = .settings }
        )
    }

    private var sheetContent: some View {
        LayersSheetContent(
            layers: sortedLayers,
            placeCount: places.count,
            viewModel: viewModel,
            filterVM: filterVM,
            searchState: searchState,
            transitSettings: transitSettings,
            transitStore: transitStore,
            timetable: timetable,
            searchActions: SheetSearchActions(
                onSelectPlace: { place in
                    showResult(at: place.coordinate)
                    viewModel.selectPlace(place)
                },
                onSelectStop: { stop in
                    showResult(at: stop.coordinate)
                    viewModel.showTransitArrivals(for: stop)
                },
                onSelectRoute: { route in
                    dismissSearch()
                    sheetDetent = .collapsed
                    transitStore.toggleHighlightedRoute(route.id)
                },
                onSelectPOI: { item in
                    showResult(at: item.placemark.coordinate)
                    viewModel.showPOI(item)
                }
            )
        )
    }

    // MARK: - Store feeding

    private func feedStore(_ snapshot: Snapshot) {
        let trails = trailSnapshotter.trails(for: layers, in: modelContext)
        store.update(places: snapshot.places, layers: snapshot.layers, trails: trails)
    }

    // MARK: - Gestures

    private func handleTap(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?) {
        // First tap on the map only dismisses the keyboard.
        if isSearchFocused {
            isSearchFocused = false
            return
        }
        // If a sheet is already showing (from a previous tap), don't POI search
        if viewModel.activeSheet != nil { return }
        guard let coordinate else { return }
        // TRAIL HOOK: hit-test trails here (TrailHitTester) and call
        // `viewModel.showTrailDetail(trailId)` before falling back to POIs.
        poiSearchTask?.cancel()
        poiSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, viewModel.activeSheet == nil else { return }
            if let item = await POILookup.nearestItem(to: coordinate), !Task.isCancelled {
                viewModel.showPOI(item)
            }
        }
    }

    private func handleLongPress(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        // Cancel any pending POI search from a near-simultaneous tap.
        poiSearchTask?.cancel()
        viewModel.startNewPlace(at: coordinate)
    }

    /// Zooms into a far-zoom cluster's grid cell so its members resolve to pins.
    private func zoom(to cluster: ClusterLite) {
        let span = MKCoordinateSpan(latitudeDelta: max(cluster.cellLatDelta * 2.5, 0.01),
                                    longitudeDelta: max(cluster.cellLonDelta * 2.5, 0.01))
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(MKCoordinateRegion(center: cluster.coordinate, span: span))
        }
    }

    private func focus(on coordinate: CLLocationCoordinate2D) {
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }

    /// A search result was picked: close search, drop the sheet and centre it.
    private func showResult(at coordinate: CLLocationCoordinate2D) {
        dismissSearch()
        sheetDetent = .collapsed
        focus(on: coordinate)
    }

    private func dismissSearch() {
        isSearchFocused = false
        searchState.clearSearch()
    }

    private func cycleMapStyle() {
        let next = mapStyleOption.next
        mapStyleOption = next
        toastCenter.show(next.rawValue, systemImage: next.icon, duration: .seconds(1.2))
    }

    // MARK: - Sheet Router

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .placeDetail(let place):
            PlaceDetailSheet(place: place)
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .poiDetail(let mapItem):
            POIAddToLayerView(mapItem: mapItem, onDismiss: { viewModel.dismissSheet() })
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .newPlace(let coordinate):
            PlaceFormView(coordinate: coordinate, mapCenter: transitStore.region.center)

        case .transitArrivals(let stop):
            TransitArrivalsView(stop: stop,
                                onSelectRoute: { routeId in transitStore.toggleHighlightedRoute(routeId) })
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .layerDetail(let id):
            if let layer = layers.first(where: { $0.id == id }) {
                NavigationStack {
                    LayerDetailView(layer: layer)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { viewModel.dismissSheet() }
                            }
                        }
                }
            } else {
                missingLayer
            }

        case .newLayer:
            LayerFormView(layer: nil)

        case .editLayer(let id):
            if let layer = layers.first(where: { $0.id == id }) {
                LayerFormView(layer: layer)
            } else {
                missingLayer
            }

        case .trailDetail(let id):
            // TRAIL HOOK: swap the placeholder for the trail detail view.
            TrailDetailPlaceholder(trailId: id)
                .presentationDetents([.medium, .large])

        case .settings:
            SettingsView()
        }
    }

    private var missingLayer: some View {
        StatusView(status: .empty(title: "This layer was deleted", hint: nil,
                                  systemImage: "square.3.layers.3d", action: nil))
            .presentationDetents([.fraction(0.25)])
    }
}
