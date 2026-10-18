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
    /// Tap-lookup status pill; nil when hidden.
    @State private var lookupPill: LookupPill.Phase?
    /// Camera region when the current tap lookup started; moving away cancels it.
    @State private var lookupRegion: MKCoordinateRegion?
    /// Long-press pin, shown while the quick-add sheet is open.
    @State private var droppedPin: CLLocationCoordinate2D?
    @State private var dropCount = 0
    @State private var trailHitCount = 0
    /// Set by the trail detail sheet's Edit; opened once that sheet has
    /// finished dismissing (the sheet's `onDismiss`).
    @State private var pendingTrailEdit: DrawTrailRequest?
    @State private var draftStore = TrailDraftStore.shared
    @AppStorage("lastTrailLayerId") private var lastTrailLayerIdRaw: String = ""

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
                droppedPin: droppedPin,
                onTapPlace: { id in
                    if let place = places.first(where: { $0.id == id }) { viewModel.selectPlace(place) }
                },
                onTapCluster: zoom(to:),
                onTapStop: { stop in viewModel.showTransitArrivals(for: stop) },
                onTap: handleTap,
                onLongPress: handleLongPress,
                onCameraChange: cancelLookupIfMoved(_:),
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
                      draftChip: draftChip,
                      onCycleMapStyle: cycleMapStyle)
                .animation(.easeInOut(duration: 0.2), value: draftStore.hasDraft)

            if let lookupPill {
                LookupPill(phase: lookupPill)
                    .padding(.top, 8)
                    .padding(.horizontal, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

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
        .animation(.easeInOut(duration: 0.15), value: lookupPill)
        .sensoryFeedback(.impact(weight: .medium), trigger: dropCount)
        .sensoryFeedback(.selection, trigger: trailHitCount)
        .onAppear { locationManager.requestPermission() }
        .onChange(of: viewModel.activeSheet?.id) { _, _ in
            // The dropped pin lives exactly as long as the quick-add sheet.
            if !viewModel.isQuickAddOpen { droppedPin = nil }
        }
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
        #if DEBUG
        .task { openDebugScreens() }
        #endif
        .sheet(item: $viewModel.activeSheet, onDismiss: openPendingTrailEdit) { sheet in
            sheetContent(for: sheet)
                .environment(toastCenter)
                .environment(\.mapCenter, transitStore.region.center)
        }
        .fullScreenCover(item: $viewModel.drawTrailRequest) { request in
            trailEditor(for: request)
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
            onDrawTrail: { startDrawTrail(in: nil) },
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

    /// Tap on the map: a trail under the finger opens its detail; otherwise
    /// look up the place there, with a status pill shown within 100 ms.
    private func handleTap(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?, _ proxy: MapProxy) {
        // First tap on the map only dismisses the keyboard.
        if isSearchFocused {
            isSearchFocused = false
            return
        }
        // If a sheet is already showing (from a previous tap), don't POI search
        if viewModel.activeSheet != nil { return }
        guard let coordinate else { return }
        // Project only trails whose bbox contains the tap, while the camera
        // is exactly where the user tapped.
        let candidates = TrailHitTester.project(store.output.trails, using: proxy, bboxContaining: coordinate)
        let hitTrail = TrailHitTester.hit(tap: screenPoint, trails: candidates)
        cancelLookup()
        poiSearchTask = Task {
            // Short disambiguation window: a tap on a pin or stop also reaches
            // the map's tap gesture, and their own handler sets the sheet.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, viewModel.activeSheet == nil else { return }
            if let hitTrail {
                trailHitCount += 1
                viewModel.showTrailDetail(hitTrail)
                return
            }
            lookupRegion = store.region
            lookupPill = .searching
            let item = await POILookup.nearestItem(to: coordinate)
            guard !Task.isCancelled else { return }
            if let item, viewModel.activeSheet == nil {
                lookupPill = nil
                viewModel.showPOI(item)
                return
            }
            lookupPill = .nothingFound
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            lookupPill = nil
        }
    }

    /// Stops any tap lookup and hides its pill.
    private func cancelLookup() {
        poiSearchTask?.cancel()
        poiSearchTask = nil
        lookupRegion = nil
        lookupPill = nil
    }

    /// A pan or zoom while "Finding place…" means the user moved on.
    private func cancelLookupIfMoved(_ region: MKCoordinateRegion) {
        guard lookupPill == .searching, let start = lookupRegion else { return }
        let dLat = abs(region.center.latitude - start.center.latitude)
        let dLon = abs(region.center.longitude - start.center.longitude)
        let zoom = abs(region.span.latitudeDelta - start.span.latitudeDelta)
        if dLat > start.span.latitudeDelta * 0.02 || dLon > start.span.longitudeDelta * 0.02
            || zoom > start.span.latitudeDelta * 0.02 {
            cancelLookup()
        }
    }

    /// Long-press: drop a pin with a haptic right away, then open quick add.
    private func handleLongPress(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        // Cancel any pending POI search from a near-simultaneous tap.
        cancelLookup()
        if isSearchFocused { isSearchFocused = false }
        dropCount += 1
        droppedPin = coordinate
        viewModel.startQuickAdd(at: coordinate)
    }

    // MARK: - Trails

    /// Opens the editor. With no layer (the "+" menu) it uses the last trail
    /// layer, else the first, else creates "Trails".
    private func startDrawTrail(in layerId: UUID?, trailId: UUID? = nil, resuming: TrailDraft? = nil) {
        let resolved = layerId
            ?? SmartDefaultLayer.trailLayer(in: layers.map(LayerLite.init),
                                            lastTrailLayerId: UUID(uuidString: lastTrailLayerIdRaw))
            ?? createTrailsLayer().id
        viewModel.requestDrawTrail(in: resolved, trailId: trailId, resuming: resuming)
    }

    private func createTrailsLayer() -> Layer {
        let layer = Layer.insertDefault(named: SmartDefaultLayer.fallbackTrailLayerName,
                                        kind: .waypointPath, symbolName: "figure.walk",
                                        after: layers, in: modelContext)
        try? modelContext.save()
        return layer
    }

    @ViewBuilder
    private func trailEditor(for request: DrawTrailRequest) -> some View {
        if let layerId = request.layerId, let layer = layer(withId: layerId) {
            TrailEditorView(layer: layer,
                            trail: request.trailId.flatMap(trail(withId:)),
                            resuming: request.resuming) { _ in
                finishTrailEditing(layerId: layer.id)
            }
        } else {
            NavigationStack {
                StatusView(status: .empty(title: "This layer was deleted", hint: nil,
                                          systemImage: "square.3.layers.3d", action: nil))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { viewModel.drawTrailRequest = nil }
                        }
                    }
            }
        }
    }

    /// The editor never dismisses itself: close it, remember the layer and
    /// redraw its trails (edits that keep the point count included).
    private func finishTrailEditing(layerId: UUID) {
        viewModel.drawTrailRequest = nil
        lastTrailLayerIdRaw = layerId.uuidString
        refreshTrails(layerId: layerId)
    }

    private func refreshTrails(layerId: UUID?) {
        if let layerId {
            trailSnapshotter.invalidate(layerId: layerId)
        } else {
            trailSnapshotter.invalidateAll()
        }
        feedStore(snapshot)
    }

    /// Runs after any router sheet finishes dismissing; opens the editor the
    /// trail detail sheet's Edit asked for.
    private func openPendingTrailEdit() {
        guard let request = pendingTrailEdit else { return }
        pendingTrailEdit = nil
        viewModel.drawTrailRequest = request
    }

    private var draftChip: DraftResumeChip? {
        guard let pending = draftStore.pending else { return nil }
        return DraftResumeChip(
            onResume: {
                guard layer(withId: pending.layerId) != nil else {
                    draftStore.clear()
                    toastCenter.show("That draft's layer was deleted", systemImage: "exclamationmark.circle")
                    return
                }
                startDrawTrail(in: pending.layerId, trailId: pending.trailId, resuming: pending.draft)
            },
            onDiscard: { draftStore.clear() }
        )
    }

    private func layer(withId id: UUID) -> Layer? {
        if let layer = layers.first(where: { $0.id == id }) { return layer }
        // A layer inserted this pass may not be in the @Query results yet.
        var descriptor = FetchDescriptor<Layer>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func trail(withId id: UUID) -> Trail? {
        var descriptor = FetchDescriptor<Trail>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
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

        case .newPlace(let coordinate, let name, let layerId):
            PlaceFormView(coordinate: coordinate, mapCenter: transitStore.region.center,
                          name: name, preselectedLayerId: layerId)

        case .quickAdd(let coordinate):
            QuickAddPlaceSheet(coordinate: coordinate) { name, layerId in
                viewModel.activeSheet = .newPlace(coordinate, name: name.isEmpty ? nil : name, layerId: layerId)
            }

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
            if let trail = trail(withId: id) {
                TrailDetailSheet(
                    trail: trail,
                    onEdit: {
                        pendingTrailEdit = DrawTrailRequest(layerId: trail.layer?.id, trailId: trail.id)
                    },
                    onDelete: { refreshTrails(layerId: nil) }
                )
            } else {
                StatusView(status: .empty(title: "This trail was deleted", hint: nil,
                                          systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                          action: nil))
                    .presentationDetents([.fraction(0.25)])
            }

        case .settings:
            SettingsView()
        }
    }

    #if DEBUG
    /// Launch arguments that open screens for simulator screenshots:
    /// `-openQuickAdd 53.3438,-6.2546` and `-openTrailEditor YES`.
    private func openDebugScreens() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "openQuickAdd"), let c = CoordinateText.parse(raw) {
            droppedPin = c
            focus(on: c)
            viewModel.startQuickAdd(at: c)
        } else if defaults.bool(forKey: "openTrailEditor") {
            startDrawTrail(in: nil)
        }
    }
    #endif

    private var missingLayer: some View {
        StatusView(status: .empty(title: "This layer was deleted", hint: nil,
                                  systemImage: "square.3.layers.3d", action: nil))
            .presentationDetents([.fraction(0.25)])
    }
}
