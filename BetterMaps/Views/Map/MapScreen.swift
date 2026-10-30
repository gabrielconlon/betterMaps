import SwiftUI
import MapKit
import SwiftData
import CoreData

/// The map screen: owns the SwiftData queries, view models and the
/// `MapContentStore`, routes sheets, and composes `MapCanvas`, the map
/// chrome, the layers panel and the persistent bottom sheet. Everything the `Map` draws comes
/// from `store.output` or value arrays — SwiftData objects never reach the
/// map content.
struct MapScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var layers: [Layer]
    @Query private var places: [Place]

    @State private var viewModel = MapViewModel()
    @State private var tagFilter = TagFilter()
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
    /// Resolving a tapped Apple transit icon to our stop. While set, the
    /// map's plain tap handler (which sees the same tap) stands down.
    @State private var transitFeatureTask: Task<Void, Never>?
    /// The slide-in layers panel (top-left button).
    @State private var isLayersPanelOpen = false
    /// Long-press pin, shown while the quick-add sheet is open.
    @State private var droppedPin: CLLocationCoordinate2D?
    @State private var dropCount = 0
    @State private var trailHitCount = 0
    /// Set by the trail detail sheet's Edit; opened once that sheet has
    /// finished dismissing (the sheet's `onDismiss`).
    @State private var pendingTrailEdit: DrawTrailRequest?
    @State private var draftStore = TrailDraftStore.shared
    @AppStorage("lastTrailLayerId") private var lastTrailLayerIdRaw: String = ""
    @AppStorage(FirstRunHints.storageKey) private var hintsRaw = 0
    /// The first-run welcome was finished (or closed) once.
    @AppStorage(WelcomeGate.storageKey) private var welcomeCompleted = false
    /// The welcome walkthrough is up. Independent of `activeSheet`: it comes
    /// before any router sheet, and Settings re-presents it after its own
    /// sheet has gone (see `pendingWelcome`).
    @State private var showWelcome = false
    @State private var pendingWelcome = false
    @State private var decidedWelcome = false
    /// Cached value snapshot of places and layers, rebuilt only when the
    /// full `SnapshotToken` changes. That token is computed outside the body,
    /// only when the cheap `snapshotTrigger` changes.
    @State private var snapshot = Snapshot()
    @State private var cachedToken: SnapshotToken?
    /// Bumped on every SwiftData save (local or remote) so edits that keep
    /// the counts (rename, move, membership) still refresh the snapshot.
    @State private var dataChangeToken = 0
    /// The locate button asked for permission; centre on the first fix.
    @State private var pendingLocate = false
    /// The stop sheet's detent, so drawing a route can drop it to the peek
    /// height and show the route instead of covering it.
    @State private var arrivalsDetent: PresentationDetent = Self.arrivalsPeek
    private static var arrivalsPeek: PresentationDetent { .fraction(0.3) }
    /// Public transport directions; one planner for the screen's lifetime.
    @State private var directions = DirectionsViewModel(provider: JourneyProviderFactory.make(),
                                                        weather: JourneyProviderFactory.makeWeather(),
                                                        cycling: JourneyProviderFactory.makeCycling())
    /// The directions sheet's detent: picking an option drops it to the
    /// peek height so the drawn journey shows.
    @State private var directionsDetent: PresentationDetent = .medium
    static let directionsPeek: PresentationDetent = .fraction(0.3)

    private static var initialDetent: SheetDetent {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sheetMedium") { return .medium }
        #endif
        return .collapsed
    }

    // MARK: - Snapshots

    /// Value snapshot of the SwiftData graph that feeds the store, the
    /// layers panel and the sheet's management lists.
    private struct Snapshot: Equatable {
        var places: [PlaceLite] = []
        var layers: [LayerLite] = []
        var layersById: [UUID: LayerLite] = [:]
        /// Tags and trail groups in sortOrder, with counts.
        var lists = SheetLayerLists()
    }

    /// Change detector for the snapshot: counts, newest place edit,
    /// per-layer fields (including membership counts, so adding a place to
    /// a second layer is seen) and the trail store fingerprint. O(places)
    /// reads plus two fetches, so it is built only from `rebuildSnapshot`,
    /// never in the body.
    private struct SnapshotToken: Equatable {
        let placeCount: Int
        let latestPlaceUpdate: Date?
        let layerCount: Int
        let layerHash: Int
        let trails: TrailSnapshotter.StoreFingerprint
    }

    private func currentSnapshotToken() -> SnapshotToken {
        var hasher = Hasher()
        for layer in layers {
            hasher.combine(layer.id)
            hasher.combine(layer.isVisible)
            hasher.combine(layer.isFavorite)
            hasher.combine(layer.sortOrder)
            hasher.combine(layer.name)
            hasher.combine(layer.colorHex)
            hasher.combine(layer.symbolName)
            hasher.combine(layer.kindRaw)
            hasher.combine(layer.lineWidth)
            hasher.combine(layer.places?.count ?? 0)
        }
        return SnapshotToken(placeCount: places.count,
                             latestPlaceUpdate: places.lazy.map(\.updatedAt).max(),
                             layerCount: layers.count,
                             layerHash: hasher.finalize(),
                             trails: TrailSnapshotter.fingerprint(in: modelContext))
    }

    /// Cheap body-side key: query counts, the save counter and the layers'
    /// own scalar fields (a handful of layers; no relationships, no places),
    /// which catches unsaved show/hide toggles.
    private struct SnapshotTrigger: Equatable {
        let placeCount: Int
        let layerCount: Int
        let layerHash: Int
        let dataChange: Int
    }

    private var snapshotTrigger: SnapshotTrigger {
        var hasher = Hasher()
        for layer in layers {
            hasher.combine(layer.id)
            hasher.combine(layer.isVisible)
            hasher.combine(layer.isFavorite)
            hasher.combine(layer.sortOrder)
            hasher.combine(layer.name)
            hasher.combine(layer.colorHex)
            hasher.combine(layer.symbolName)
            hasher.combine(layer.kindRaw)
            hasher.combine(layer.lineWidth)
        }
        return SnapshotTrigger(placeCount: places.count, layerCount: layers.count,
                               layerHash: hasher.finalize(), dataChange: dataChangeToken)
    }

    private var layersById: [UUID: LayerLite] { snapshot.layersById }

    /// What the store draws: the tag selection plus the Places and Trails
    /// switches. Changes only on a user action, never with the camera.
    private var placeFilter: PlaceFilter {
        PlaceFilter(tagIds: tagFilter.selectedTagIds, match: tagFilter.match,
                    showPlaces: transitSettings.showPlaces, showTrails: transitSettings.showTrails)
    }

    /// Settled map centre for "add a place here" forms. The stores' region
    /// is unobserved, so reading it never ties a body to the camera.
    private var settledMapCenter: CLLocationCoordinate2D { store.region.center }

    private var canLocateUser: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
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
                transitStore: transitStore,
                droppedPin: droppedPin,
                onTapPlace: { id in
                    if store.output.places.contains(where: { $0.id == id && $0.showsOverlap }) {
                        markHintDone(.overlap)
                    }
                    if let place = places.first(where: { $0.id == id }) { viewModel.selectPlace(place) }
                },
                onTapCluster: zoom(to:),
                onTapStop: { stop in viewModel.showTransitArrivals(for: stop) },
                onTapTransitFeature: handleTransitFeatureTap,
                onTap: handleTap,
                onLongPress: handleLongPress,
                onCameraSettled: { region in
                    transitStore.region = region
                    if isSearchFocused { isSearchFocused = false }
                }
            )
            .ignoresSafeArea(.keyboard)

            if isLayersPanelOpen {
                // A tap anywhere on the map closes the panel.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { setLayersPanel(open: false) }
                    .accessibilityHidden(true)
            }

            MapChrome(mapScope: mapScope,
                      isHidden: sheetDetent == .expanded,
                      isLayersOpen: isLayersPanelOpen,
                      onToggleLayers: { setLayersPanel(open: !isLayersPanelOpen) },
                      draftChip: draftChip,
                      routeChip: routeChip,
                      canLocateUser: canLocateUser,
                      onRequestLocation: locateUser)
                .animation(.easeInOut(duration: 0.2), value: draftStore.hasDraft)
                .animation(.easeInOut(duration: 0.2), value: transitStore.highlightedRouteId)
                .animation(.easeInOut(duration: 0.2), value: directionsDrawn)

            if isLayersPanelOpen {
                layersPanel
                    .padding(.leading, 12)
                    // Below the 44pt Layers button, above the sheet.
                    .padding(.top, 8 + 44 + 8)
                    .padding(.bottom, sheetHeight + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // A router sheet (stop, place, form…) stands in for the search
            // sheet rather than stacking on it: two sheets showed two
            // grabbers and overlapping panels.
            BottomSheet(detent: $sheetDetent,
                        onSettledHeightChange: { sheetHeight = $0 },
                        header: { sheetHeader },
                        content: { sheetContent })
                .opacity(isRouterSheetOpen ? 0 : 1)
                .allowsHitTesting(!isRouterSheetOpen)
                .accessibilityHidden(isRouterSheetOpen)
                .animation(.easeInOut(duration: 0.2), value: isRouterSheetOpen)

            // Toast host: clear and untouchable itself, its toast sits just
            // above the sheet.
            Color.clear
                .allowsHitTesting(false)
                .toasts(toastCenter)
                .padding(.bottom, sheetHeight)
        }
        .mapScope(mapScope)
        .environment(toastCenter)
        .animation(.easeInOut(duration: 0.25), value: isLayersPanelOpen)
        .sensoryFeedback(.impact(weight: .medium), trigger: dropCount)
        .sensoryFeedback(.selection, trigger: trailHitCount)
        // Location is requested on first use (locate, quick add, search),
        // not at launch; an existing grant still shows the blue dot.
        .onChange(of: locationManager.userLocation?.latitude) { _, _ in
            centreOnUserIfPending()
            // The first fix after permission was granted fills in "My Location"
            // for a directions sheet that opened without one.
            if let location = locationManager.userLocation { directions.userLocationDidUpdate(location) }
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            if status == .denied || status == .restricted { pendingLocate = false }
        }
        .onChange(of: viewModel.activeSheet?.id) { _, _ in
            // The dropped pin lives exactly as long as the quick-add sheet.
            if !viewModel.isQuickAddOpen { droppedPin = nil }
            guard let sheet = viewModel.activeSheet else { return }
            // The hidden search sheet comes back collapsed, so the map the
            // router sheet was about is still in view when it closes.
            if isSearchFocused { isSearchFocused = false }
            if sheetDetent != .collapsed { sheetDetent = .collapsed }
            if case .transitArrivals = sheet { arrivalsDetent = Self.arrivalsPeek }
            if case .directions = sheet { requestLocationIfUndetermined() }
        }
        // The directions sheet has one fixed id so a new destination re-plans
        // inside it rather than re-presenting; this is what notices the
        // destination itself, on open and on re-targeting alike.
        .onChange(of: directionsDestination) { _, destination in
            guard let destination else {
                if directions.isPresented { directions.sheetDismissed() }
                return
            }
            directionsDetent = .medium
            directions.attach(context: modelContext)
            directions.isPresented = true
            directions.start(destination: destination, userLocation: directionsOrigin)
        }
        .onChange(of: snapshotTrigger, initial: true) { _, _ in rebuildSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .receive(on: RunLoop.main)) { _ in
            dataChangeToken &+= 1
            // Settings (or another device) may have changed the directions
            // preferences; the open sheet re-plans if so.
            directions.refreshPrefs()
        }
        .onReceive(NotificationCenter.default.publisher(for: TrailSnapshotter.didChangeNotification)) { _ in
            feedStore(snapshot)
        }
        .onChange(of: placeFilter, initial: true) { _, filter in
            store.filter = filter
        }
        .onChange(of: transitSettings.enabledKinds, initial: true) { _, kinds in
            transitStore.enabledKinds = kinds
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused {
                sheetDetent = .expanded
                requestLocationIfUndetermined()
            }
        }
        .onChange(of: sheetDetent) { _, detent in
            if detent == .collapsed, isSearchFocused { isSearchFocused = false }
            if detent != .collapsed, isLayersPanelOpen { setLayersPanel(open: false) }
        }
        // Transit data is decoded only once a transit layer is on; a user
        // with every transit kind off does no transit work at launch.
        .task(id: transitSettings.enabledKinds.isEmpty) {
            guard !transitSettings.enabledKinds.isEmpty else { return }
            await transitStore.loadIfNeeded()
            await BusTimetableService.shared.refreshIfStale(days: 14, bundleBuilt: TransitBundle.builtDate(in: .main))
        }
        #if DEBUG
        .task { openDebugScreens() }
        .task {
            await PerfHarness.runIfRequested(camera: $cameraPosition, contentStore: store,
                                             transitStore: transitStore, settings: transitSettings,
                                             modelContext: modelContext)
        }
        #endif
        .sheet(item: $viewModel.activeSheet, onDismiss: routerSheetDismissed) { sheet in
            sheetContent(for: sheet)
                .environment(toastCenter)
                .environment(\.mapCenter, settledMapCenter)
        }
        .fullScreenCover(item: $viewModel.drawTrailRequest) { request in
            trailEditor(for: request)
                .environment(toastCenter)
        }
        .onAppear(perform: decideWelcome)
        #if targetEnvironment(macCatalyst)
        .sheet(isPresented: $showWelcome, onDismiss: welcomeDismissed) {
            WelcomeWalkthrough(transitSettings: transitSettings, onFinish: finishWelcome)
        }
        #else
        .fullScreenCover(isPresented: $showWelcome, onDismiss: welcomeDismissed) {
            WelcomeWalkthrough(transitSettings: transitSettings, onFinish: finishWelcome)
        }
        #endif
    }

    // MARK: - Welcome

    /// Once per screen: the first-run walkthrough shows when it has never
    /// been finished and no automation drives this launch (`WelcomeGate`).
    private func decideWelcome() {
        guard !decidedWelcome else { return }
        decidedWelcome = true
        if WelcomeGate.resetRequested { welcomeCompleted = false }
        guard WelcomeGate.shouldShowNow(completed: welcomeCompleted) else { return }
        // Nothing opens underneath it: a router sheet already up (a debug
        // launch) keeps the map, and the walkthrough waits for Settings.
        guard viewModel.activeSheet == nil else { return }
        showWelcome = true
    }

    private func finishWelcome() {
        welcomeCompleted = true
        showWelcome = false
    }

    /// Closing it any other way (Escape on the Mac) counts as finished too,
    /// so it does not come back on every launch.
    private func welcomeDismissed() {
        welcomeCompleted = true
    }

    /// Settings' "Show the welcome again": the walkthrough is presented once
    /// the Settings sheet has gone, so the two never stack.
    private func routerSheetDismissed() {
        openPendingTrailEdit()
        if pendingWelcome {
            pendingWelcome = false
            welcomeCompleted = false
            showWelcome = true
        }
    }

    // MARK: - Sheet

    private var sheetHeader: some View {
        LayersSheetHeader(
            searchState: searchState,
            isSearchFocused: $isSearchFocused,
            detent: sheetDetent,
            onSearchTextChanged: {
                searchState.debouncedSearch(places: places, transit: transitStore,
                                            userLocation: locationManager.userLocation)
            },
            onCancelSearch: {
                dismissSearch()
                sheetDetent = .collapsed
            },
            onAddPlace: {
                requestLocationIfUndetermined()
                viewModel.startNewPlace(at: nil)
            },
            onDrawTrail: { startDrawTrail(in: nil) },
            onNewTag: { viewModel.activeSheet = .newLayer(.places) },
            onOpenSettings: { viewModel.activeSheet = .settings }
        )
    }

    private var sheetContent: some View {
        LayersSheetContent(
            lists: snapshot.lists,
            placeCount: places.count,
            viewModel: viewModel,
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
                    transitStore.toggleHighlightedRoute(route.id, label: TransitArrivalsView.routeLabel(route.short))
                },
                onSelectPOI: { item in
                    showResult(at: item.placemark.coordinate)
                    viewModel.showPOI(item)
                },
                onDirections: { endpoint in
                    dismissSearch()
                    sheetDetent = .collapsed
                    viewModel.showDirections(to: endpoint)
                }
            ),
            onDrawTrail: { startDrawTrail(in: $0) }
        )
    }

    // MARK: - Layers panel

    private var layersPanel: some View {
        LayersPanel(
            input: LayersPanelInput(tags: snapshot.lists.tags, trailGroups: snapshot.lists.trailGroups),
            tagFilter: tagFilter,
            settings: transitSettings,
            store: store,
            mapStyle: $mapStyleOption,
            onClose: { setLayersPanel(open: false) },
            onToggleFavorite: { id in layer(withId: id)?.isFavorite.toggle() },
            onToggleTrailGroup: { id in layer(withId: id)?.isVisible.toggle() },
            onNewTag: {
                setLayersPanel(open: false)
                viewModel.activeSheet = .newLayer(.places)
            },
            onFilterChanged: {
                if tagFilter.match == .all, tagFilter.selectedTagIds.count >= 2 { markHintDone(.overlap) }
            }
        )
    }

    private var isRouterSheetOpen: Bool { viewModel.activeSheet != nil }

    /// The destination the open directions sheet is about; nil when another
    /// sheet, or none, is up.
    private var directionsDestination: DirectionsEndpoint? {
        if case .directions(let destination) = viewModel.activeSheet { return destination }
        return nil
    }

    /// A picked journey or the search's previews are on the map.
    private var directionsDrawn: Bool {
        transitStore.drawnItinerary != nil || !transitStore.previewItineraries.isEmpty
    }

    private var routeChip: HighlightedRouteChip? {
        if directionsDrawn {
            let label = transitStore.drawnItinerary != nil ? directions.drawnLabel : nil
            return HighlightedRouteChip(label: label ?? "Directions",
                                        onClear: { directions.clearMap() },
                                        systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                                        tint: .accentColor,
                                        prefix: nil,
                                        accessibilityIdentifier: "directions.clear")
        }
        guard transitStore.highlightedRouteId != nil else { return nil }
        return HighlightedRouteChip(label: transitStore.highlightedRouteLabel,
                                    onClear: { transitStore.clearHighlightedRoute() })
    }

    /// Where a journey starts: the user's location when known. Under the
    /// UI-test fixture flag, a fixed Dublin point stands in so the fake
    /// planner has something to plan from without location access.
    private var directionsOrigin: CLLocationCoordinate2D? {
        if let location = locationManager.userLocation { return location }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestFakeDirections") {
            return CLLocationCoordinate2D(latitude: 53.3464, longitude: -6.2923)
        }
        #endif
        return nil
    }

    private func setLayersPanel(open: Bool) {
        guard open != isLayersPanelOpen else { return }
        if open {
            if isSearchFocused { isSearchFocused = false }
            if sheetDetent != .collapsed { sheetDetent = .collapsed }
            markHintDone(.toggleLayer)
        }
        isLayersPanelOpen = open
    }

    // MARK: - Store feeding

    /// Runs when `snapshotTrigger` changes: rebuilds the value snapshot if
    /// the full token says something changed, then feeds the store.
    private func rebuildSnapshot() {
        let token = currentSnapshotToken()
        guard token != cachedToken else { return }
        cachedToken = token
        let layerLites = layers.map(LayerLite.init)
        let placeLites = places.map(PlaceLite.init)
        let sorted = layerLites.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        let tags = sorted.filter { $0.kind == .places }

        var tagCounts: [UUID: Int] = [:]
        for place in placeLites {
            for id in place.layerIds { tagCounts[id, default: 0] += 1 }
        }
        var trailStats: [UUID: TrailGroupStats] = [:]
        for layer in layers where layer.kind == .waypointPath {
            let trails = layer.trails ?? []
            trailStats[layer.id] = TrailGroupStats(count: trails.count,
                                                   meters: trails.reduce(0) { $0 + $1.distanceMeters })
        }

        snapshot = Snapshot(
            places: placeLites,
            layers: layerLites,
            layersById: Dictionary(layerLites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            lists: SheetLayerLists(tags: tags,
                                   trailGroups: sorted.filter { $0.kind == .waypointPath },
                                   tagCounts: tagCounts,
                                   trailStats: trailStats)
        )
        tagFilter.migrateIfNeeded(tags: tags)
        tagFilter.prune(existingTagIds: Set(tags.map(\.id)))
        feedStore(snapshot)
    }

    private func markHintDone(_ hint: FirstRunHints.Hint) {
        var hints = FirstRunHints(rawValue: hintsRaw)
        hints.markDone(hint)
        if hints.rawValue != hintsRaw { hintsRaw = hints.rawValue }
    }

    private func feedStore(_ snapshot: Snapshot) {
        let trails = trailSnapshotter.trails(for: layers, in: modelContext)
        store.update(places: snapshot.places, layers: snapshot.layers, trails: trails)
    }

    // MARK: - Gestures

    /// Screen radius within which a tap opens a far-zoom transit dot.
    private static let stopDotTapRadius: CGFloat = 22

    /// Tap on the map: a transit dot or trail under the finger opens its
    /// detail; otherwise the place sheet opens at once and looks up the
    /// place there (no status floats over the map).
    private func handleTap(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?, _ proxy: MapProxy) {
        // First tap on the map only dismisses the keyboard.
        if isSearchFocused {
            isSearchFocused = false
            return
        }
        // If a sheet is already showing (from a previous tap), don't POI search
        if let sheet = viewModel.activeSheet {
            #if targetEnvironment(macCatalyst)
            // No swipe down on the Mac: a click on the map closes a map card,
            // as clicking away from a card does in Maps.
            if sheet.isMapCard { viewModel.dismissSheet() }
            #else
            _ = sheet
            #endif
            return
        }
        guard let coordinate else { return }
        // Project only trails whose bbox contains the tap, while the camera
        // is exactly where the user tapped.
        let candidates = TrailHitTester.project(store.output.trails, using: proxy, bboxContaining: coordinate)
        let hitTrail = TrailHitTester.hit(tap: screenPoint, trails: candidates)
        let hitStop = stopDot(near: screenPoint, coordinate: coordinate, proxy: proxy)
        cancelLookup()
        poiSearchTask = Task {
            // Short disambiguation window: a tap on a pin or stop also reaches
            // the map's tap gesture, and their own handler sets the sheet.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, viewModel.activeSheet == nil, transitFeatureTask == nil else { return }
            if let hitStop {
                viewModel.showTransitArrivals(for: hitStop)
                return
            }
            if let hitTrail {
                trailHitCount += 1
                viewModel.showTrailDetail(hitTrail)
                return
            }
            // With a route or journey drawn, a tap on empty map clears it
            // (as in Maps) rather than looking up a place.
            if transitStore.highlightedRouteId != nil {
                transitStore.clearHighlightedRoute()
                return
            }
            if directionsDrawn {
                directions.clearMap()
                return
            }
            viewModel.lookUpPlace(at: coordinate)
        }
    }

    /// Tap on Apple's own station / stop icon: open our timetable for the
    /// stop it stands for (matched by name and distance), else the place
    /// sheet, as a tap there did before.
    private func handleTransitFeatureTap(_ feature: MapFeature) {
        if viewModel.activeSheet != nil { return }
        cancelLookup()
        transitFeatureTask?.cancel()
        let coordinate = feature.coordinate
        let title = feature.title
        transitFeatureTask = Task {
            defer { if !Task.isCancelled { transitFeatureTask = nil } }
            // Loads the bundle even with the transit layer off: the icon is
            // on the base map either way.
            await transitStore.loadIfNeeded()
            guard !Task.isCancelled, viewModel.activeSheet == nil else { return }
            if let stop = transitStore.nearestStop(to: coordinate, title: title) {
                viewModel.showTransitArrivals(for: stop)
            } else {
                viewModel.lookUpPlace(at: coordinate)
            }
        }
    }

    /// The transit dot (dots ignore touches) within `stopDotTapRadius` of a
    /// tap, using the camera as it is at tap time.
    private func stopDot(near screenPoint: CGPoint, coordinate: CLLocationCoordinate2D,
                         proxy: MapProxy) -> TransitStop? {
        guard !transitStore.visibleStops.isEmpty,
              let edge = proxy.convert(CGPoint(x: screenPoint.x + Self.stopDotTapRadius, y: screenPoint.y),
                                       from: .local) else { return nil }
        let meters = WaypointGraph.meters(coordinate, edge)
        guard meters > 0 else { return nil }
        return transitStore.nearestDotStop(to: coordinate, within: meters)
    }

    /// Stops a pending tap (before its sheet opens).
    private func cancelLookup() {
        poiSearchTask?.cancel()
        poiSearchTask = nil
    }

    /// Long-press: drop a pin with a haptic right away, then open quick add.
    private func handleLongPress(_ screenPoint: CGPoint, _ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        // Cancel any pending POI search from a near-simultaneous tap.
        cancelLookup()
        if isSearchFocused { isSearchFocused = false }
        dropCount += 1
        droppedPin = coordinate
        requestLocationIfUndetermined()
        viewModel.startQuickAdd(at: coordinate)
    }

    // MARK: - Location

    /// Asks for When-In-Use access the first time a feature needs it.
    private func requestLocationIfUndetermined() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestPermission()
        }
    }

    /// The locate button before access is granted: ask, then centre on the
    /// first fix. If access was turned off, offer Settings in a toast.
    private func locateUser() {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            toastCenter.show("Location is off for BetterMaps", systemImage: "location.slash",
                             action: ToastAction(label: "Settings") {
                                 if let url = URL(string: UIApplication.openSettingsURLString) {
                                     UIApplication.shared.open(url)
                                 }
                             },
                             duration: .seconds(4))
        default:
            pendingLocate = true
            locationManager.requestPermission()
            centreOnUserIfPending()
        }
    }

    private func centreOnUserIfPending() {
        guard pendingLocate, let location = locationManager.userLocation else { return }
        pendingLocate = false
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: location,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
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
                StatusView(status: .empty(title: "This trail group was deleted", hint: nil,
                                          systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                          action: nil))
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
                    toastCenter.show("That draft's trail group was deleted", systemImage: "exclamationmark.circle")
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

    // MARK: - Sheet Router

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .placeDetail(let place):
            PlaceDetailSheet(place: place,
                             onDirections: { viewModel.showDirections(to: $0) },
                             onOpenStop: { viewModel.showTransitArrivals(for: $0) })
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .mapCardCloseButton { viewModel.dismissSheet() }

        case .poiDetail(let mapItem):
            POIAddToLayerView(mapItem: mapItem, onDismiss: { viewModel.dismissSheet() },
                              onDirections: { viewModel.showDirections(to: $0) },
                              onOpenStop: { viewModel.showTransitArrivals(for: $0) })
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .mapCardCloseButton { viewModel.dismissSheet() }

        case .poiLookup(let coordinate):
            POILookupSheet(coordinate: coordinate, onDismiss: { viewModel.dismissSheet() },
                           onDirections: { viewModel.showDirections(to: $0) },
                           onOpenStop: { viewModel.showTransitArrivals(for: $0) })
                .presentationDetents([.fraction(0.25), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .mapCardCloseButton { viewModel.dismissSheet() }

        case .directions:
            DirectionsSheet(
                model: directions,
                onSelectItinerary: {
                    #if !targetEnvironment(macCatalyst)
                    directionsDetent = Self.directionsPeek
                    #endif
                },
                onOpenInAppleMaps: { name, coordinate in
                    PlaceActionRow.openInAppleMaps(name: name, coordinate: coordinate)
                },
                onEditEndpoints: { directionsDetent = .large }
            )
            .presentationDetents([Self.directionsPeek, .medium, .large], selection: $directionsDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .newPlace(let coordinate, let name, let layerId):
            PlaceFormView(coordinate: coordinate, mapCenter: settledMapCenter,
                          name: name, preselectedLayerId: layerId)

        case .quickAdd(let coordinate):
            QuickAddPlaceSheet(coordinate: coordinate) { name, layerId in
                viewModel.activeSheet = .newPlace(coordinate, name: name.isEmpty ? nil : name, layerId: layerId)
            }

        case .transitArrivals(let stop):
            TransitArrivalsView(stop: stop,
                                onSelectRoute: { routeId, label in
                                    let drawing = transitStore.highlightedRouteId != routeId
                                    transitStore.toggleHighlightedRoute(routeId, label: label)
                                    // Drop to the peek height so the route is on screen.
                                    if drawing { arrivalsDetent = Self.arrivalsPeek }
                                },
                                highlightedRouteId: transitStore.highlightedRouteId)
                .presentationDetents([Self.arrivalsPeek, .medium, .large], selection: $arrivalsDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .mapCardCloseButton { viewModel.dismissSheet() }

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

        case .newLayer(let kind):
            LayerFormView(layer: nil, kind: kind)

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
                .mapCardCloseButton { viewModel.dismissSheet() }
            } else {
                StatusView(status: .empty(title: "This trail was deleted", hint: nil,
                                          systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                          action: nil))
                    .presentationDetents([.fraction(0.25)])
            }

        case .settings:
            SettingsView(onShowWelcome: { pendingWelcome = true })
        }
    }

    #if DEBUG
    /// Launch arguments that open screens for simulator screenshots:
    /// `-openQuickAdd 53.3438,-6.2546`, `-openTrailEditor YES`,
    /// `-openLayersPanel YES`, `-openPlaceDetail YES` (the first place by
    /// name, after `-PerfSeed` has run), and `-debugSelectTags 2
    /// -debugTagMatch all` (selects the first N tags by sortOrder).
    private func openDebugScreens() {
        let defaults = UserDefaults.standard
        let selectCount = defaults.integer(forKey: "debugSelectTags")
        if selectCount > 0 {
            let tags = layers.filter { $0.kind == .places }.sorted { $0.sortOrder < $1.sortOrder }
            tagFilter.selectedTagIds = Set(tags.prefix(selectCount).map(\.id))
        }
        if let match = defaults.string(forKey: "debugTagMatch").flatMap(TagMatch.init(rawValue:)) {
            tagFilter.match = match
        }
        if defaults.bool(forKey: "openLayersPanel") { isLayersPanelOpen = true }
        if let raw = defaults.string(forKey: "openQuickAdd"), let c = CoordinateText.parse(raw) {
            droppedPin = c
            focus(on: c)
            viewModel.startQuickAdd(at: c)
        } else if defaults.bool(forKey: "openTrailEditor") {
            startDrawTrail(in: nil)
        } else if defaults.bool(forKey: "openPlaceDetail") {
            // The seed runs from a sibling task; give it a moment to land.
            Task {
                try? await Task.sleep(for: .seconds(1))
                var descriptor = FetchDescriptor<Place>(sortBy: [SortDescriptor(\.name)])
                descriptor.fetchLimit = 1
                guard let place = try? modelContext.fetch(descriptor).first else { return }
                focus(on: place.coordinate)
                viewModel.selectPlace(place)
            }
        }
    }
    #endif

    private var missingLayer: some View {
        StatusView(status: .empty(title: "This tag was deleted", hint: nil,
                                  systemImage: "tag", action: nil))
            .presentationDetents([.fraction(0.25)])
    }
}
