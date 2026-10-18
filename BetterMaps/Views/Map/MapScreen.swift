import SwiftUI
import MapKit
import SwiftData

/// The map screen: owns the SwiftData queries, view models and the
/// `MapContentStore`, routes sheets, and composes `MapCanvas` with the
/// chrome. Everything the `Map` draws comes from `store.output` or value
/// arrays — SwiftData objects never reach the map content.
struct MapScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var layers: [Layer]
    @Query private var places: [Place]

    @State private var viewModel = MapViewModel()
    @State private var filterVM = LayerFilterViewModel()
    @State private var locationManager = LocationManager()
    @State private var store = MapContentStore(region: Self.launchRegion)
    @State private var trailSnapshotter = TrailSnapshotter()

    /// Default to a fixed Dublin region rather than `.userLocation(fallback:)`.
    /// `.userLocation` triggers continuous CoreLocation requests on every
    /// body recompute, which under load was hitting the kernel's 24k/sec rate
    /// limit and leaving MapKit's CAMetalLayer stuck at 0×0 (white-screen
    /// hang). The MapUserLocationButton still recenters on demand.
    private static let launchRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var cameraPosition: MapCameraPosition = .region(Self.launchRegion)
    @State private var transitState = TransitMapState()
    @State private var searchState = SearchState()
    @FocusState private var isSearchFocused: Bool
    @State private var showFavoritesPanel = false
    @State private var mapStyleOption: MapStyleOption = .standard
    @AppStorage("savedTransitStops") private var savedTransitStops = ""
    @AppStorage("hasSeenCoachMarks") private var hasSeenCoachMarks = false
    @State private var showCoachMarks = false
    @State private var poiSearchTask: Task<Void, Never>?

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

    private var visibleLayerLites: [LayerLite] {
        layers.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }.map(LayerLite.init)
    }

    private var currentMapStyle: MapStyle {
        switch mapStyleOption {
        case .standard:
            return .standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        case .muted:
            return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .all, showsTraffic: false)
        case .satellite:
            return .imagery(elevation: .realistic)
        case .hybrid:
            return .hybrid(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            MapCanvas(
                cameraPosition: $cameraPosition,
                store: store,
                layersById: layersById,
                mapStyle: currentMapStyle,
                transit: TransitLayerContent.Inputs(transitState),
                onTapPlace: { id in
                    if let place = places.first(where: { $0.id == id }) { viewModel.selectPlace(place) }
                },
                onTapCluster: zoom(to:),
                onTapStop: { stop in
                    viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate,
                                                  stopType: stop.type, stopCode: stop.stopCode, stopId: stop.id)
                },
                onTap: handleTap,
                onLongPress: handleLongPress,
                onCameraSettled: { region in
                    transitState.mapRegion = region
                    // Dismiss keyboard when user pans the map
                    if isSearchFocused { isSearchFocused = false }
                }
            )

            MapLayersOverlay(
                showFavoritesPanel: $showFavoritesPanel,
                showTransitStops: $transitState.showTransitStops,
                mapStyleOption: $mapStyleOption,
                legendLayers: visibleLayerLites,
                legendEntries: store.output.legend
            )

            VStack(spacing: 0) {
                Spacer()
                MapSearchResults(
                    searchState: searchState,
                    onSelectPlace: { place in
                        dismissSearch()
                        focus(on: place.coordinate)
                        viewModel.selectPlace(place)
                    },
                    onSelectStop: { stop in
                        dismissSearch()
                        focus(on: stop.coordinate)
                        viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate,
                                                      stopType: stop.type, stopCode: stop.stopCode, stopId: stop.id)
                    },
                    onSelectPOI: { item in
                        viewModel.showPOI(item)
                        dismissSearch()
                        focus(on: item.placemark.coordinate)
                    }
                )
                MapBottomBar(
                    searchState: searchState,
                    filterVM: filterVM,
                    isSearchFocused: $isSearchFocused,
                    activeLayerCount: store.output.visibleLayerCount,
                    onOpenMenu: { viewModel.showLayerSidebar() },
                    onSearchTextChanged: {
                        searchState.debouncedSearch(places: places, transitStops: transitState.transitStops,
                                                    userLocation: locationManager.userLocation)
                    }
                )
            }

            if showCoachMarks {
                CoachMarkOverlay(isPresented: $showCoachMarks)
                    .zIndex(100)
            }
        }
        .onAppear {
            locationManager.requestPermission()
            // Restore persisted transit toggle states
            transitState.showTransitStops = transitState.deserializeTransitTypes(savedTransitStops)

            // Show one-time coach marks for first-time users
            if !hasSeenCoachMarks {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeIn(duration: 0.3)) { showCoachMarks = true }
                }
            }
        }
        .onChange(of: snapshot, initial: true) { _, new in feedStore(new) }
        .onChange(of: filterVM.filterMode, initial: true) { _, mode in store.filterMode = mode }
        .onChange(of: transitState.showTransitStops) { _, newValue in
            savedTransitStops = transitState.serializeTransitTypes(newValue)
        }
        .onChange(of: showCoachMarks) { _, newValue in
            if !newValue { hasSeenCoachMarks = true }
        }
        .task(id: "loadTransitData") {
            await transitState.loadTransitData()
            searchState.transitDataReady = true
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(for: sheet)
        }
    }

    // MARK: - Store feeding

    private func feedStore(_ snapshot: Snapshot) {
        let trails = trailSnapshotter.trails(for: layers, in: modelContext)
        store.update(places: snapshot.places, layers: snapshot.layers, trails: trails)
    }

    // MARK: - Gestures

    private func handleTap(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?) {
        // Dismiss keyboard if searching
        if isSearchFocused {
            isSearchFocused = false
            searchState.clearSearch()
            return
        }
        // If a sheet is already showing (from a previous tap), don't POI search
        if viewModel.activeSheet != nil { return }
        guard let coordinate else { return }
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

    private func dismissSearch() {
        searchState.showSearchResults = false
        searchState.searchText = ""
    }

    // MARK: - Sheet Router

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .placeDetail(let place):
            PlaceDetailSheet(place: place)
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .poiDetail(let mapItem):
            POIAddToLayerView(mapItem: mapItem, onDismiss: { viewModel.dismissSheet() })
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .layerSidebar:
            HamburgerMenuView(
                filterMode: $filterVM.filterMode,
                showTransitStops: $transitState.showTransitStops,
                mapStyleOption: $mapStyleOption,
                onSelectPlace: { place in
                    viewModel.activeSheet = nil
                    focus(on: place.coordinate)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.selectPlace(place)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .newPlace(let coordinate):
            PlaceFormView(coordinate: coordinate)

        case .transitArrivals(let name, let coord, let type, let stopCode, let stopId):
            TransitArrivalsView(stationName: name, coordinate: coord, stopType: type,
                                stopCode: stopCode, stopId: stopId)
                // Route chips in the sheet no longer draw a route on the map
                // (the shape service went with the planner); phase 2 rewires them.
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}
