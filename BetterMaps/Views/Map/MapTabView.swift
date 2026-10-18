import SwiftUI
import MapKit
import SwiftData

struct MapTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var layers: [Layer]
    @Query private var places: [Place]
    @Query(sort: \FavoriteTransitRoute.sortOrder) private var favoriteRoutes: [FavoriteTransitRoute]

    @State private var viewModel = MapViewModel()
    @State private var filterVM = LayerFilterViewModel()
    @State private var locationManager = LocationManager()

    /// Default to a fixed Dublin region rather than `.userLocation(fallback:)`.
    /// `.userLocation` triggers continuous CoreLocation requests on every
    /// body recompute — which under load (lots of @Observable mutations
    /// during cold start) was hitting the kernel's 24k/sec rate limit and
    /// leaving MapKit's CAMetalLayer stuck at 0×0, manifesting as the
    /// white-screen hang the user reported. The MapUserLocationButton in
    /// .mapControls still recenters on demand when the user taps it.
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    ))
    @State private var transitState = TransitMapState()
    @State private var searchState = SearchState()
    @FocusState private var isSearchFocused: Bool
    @State private var showFavoritesPanel = false
    @State private var mapStyleOption: MapStyleOption = .standard
    @AppStorage("savedTransitStops") private var savedTransitStops = ""
    @AppStorage("hasSeenCoachMarks") private var hasSeenCoachMarks = false
    @State private var showCoachMarks = false
    @State private var poiSearchTask: Task<Void, Never>?

    var filteredPlaces: [Place] {
        let base = filterVM.filteredPlaces(allPlaces: places, allLayers: layers)
        // For waypoint-path layers, only show pins at the start/end. Intermediate
        // waypoints contribute to the line but aren't drawn as map pins.
        // A place is hidden only when its sole reason to render is a non-endpoint
        // waypoint membership; if it also belongs to any visible places-layer, it shows.
        return base.filter { place in
            let visibleMemberships = (place.layers ?? []).filter { $0.isVisible }
            let onlyWaypointMemberships = !visibleMemberships.isEmpty
                && visibleMemberships.allSatisfy { $0.kind == .waypointPath }
            if onlyWaypointMemberships && !place.isWaypointEndpoint { return false }
            return true
        }
    }

    /// (layer, segments) tuples for each visible waypoint-path layer.
    /// Trails draw in tap-order via orderedSegmentsByPath — MST was creating
    /// phantom Y-shape shortcuts when endpoint flags changed degree caps on
    /// non-convex routes (e.g., a path winding along a canal). Per-trail
    /// sort: by sortIndex first, falling back to createdAt for legacy data
    /// where every place has sortIndex == 0.
    var waypointPathRenderables: [(layer: Layer, segments: [[CLLocationCoordinate2D]])] {
        layers
            .filter { $0.isVisible && $0.kind == .waypointPath }
            .map { layer in
                let sorted = (layer.places ?? []).sorted { lhs, rhs in
                    if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                    return lhs.createdAt < rhs.createdAt
                }
                let nodes = sorted.map {
                    WaypointGraph.Node(
                        id: $0.id,
                        coordinate: $0.coordinate,
                        isEndpoint: $0.isWaypointEndpoint,
                        pathId: $0.pathId
                    )
                }
                return (layer, WaypointGraph.orderedSegmentsByPath(for: nodes))
            }
    }

    var activeLayerCount: Int {
        layers.filter { $0.isVisible }.count
    }

    var isOverlapMode: Bool {
        filterVM.filterMode == .intersection && activeLayerCount > 1
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

    var body: some View {
        ZStack {
            mapView
            layersPanelOverlay
            // UI overlays
            VStack(spacing: 0) {
                Spacer()

                // Search results above bottom bar
                if searchState.showSearchResults && (!searchState.placeSearchResults.isEmpty || !searchState.transitSearchResults.isEmpty || !searchState.routeSearchResults.isEmpty || !searchState.searchResults.isEmpty) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(searchState.orderedSections, id: \.self) { section in
                                switch section {
                                case .places: savedPlaceResults
                                case .routes: routeResults
                                case .transitStops: transitStopResults
                                case .pois: poiResults
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // Bottom bar: [settings] [search] [filter chips]
                bottomBar
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
                    withAnimation(.easeIn(duration: 0.3)) {
                        showCoachMarks = true
                    }
                }
            }
        }
        .onChange(of: transitState.showTransitStops) { _, newValue in
            savedTransitStops = transitState.serializeTransitTypes(newValue)
        }
        .onChange(of: showCoachMarks) { _, newValue in
            if !newValue {
                hasSeenCoachMarks = true
            }
        }
        .task(id: "loadTransitData") { await loadTransitData() }
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(for: sheet)
        }
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
            POIAddToLayerView(
                mapItem: mapItem,
                onDismiss: { viewModel.dismissSheet() }
            )
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
                    cameraPosition = .region(MKCoordinateRegion(
                        center: place.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    ))
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
            TransitArrivalsView(
                stationName: name,
                coordinate: coord,
                stopType: type,
                stopCode: stopCode,
                stopId: stopId
            )
            // Route chips in the sheet no longer draw a route on the map
            // (the shape service went with the planner); phase 2 rewires them.
            .presentationDetents([.fraction(0.3), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    // MARK: - Layers Panel Overlay

    /// Reserve enough vertical room for the bottom bar (search field + buttons).
    /// 56pt button stack + 8pt bottom padding + ~12pt buffer above the search bar.
    private static let panelBottomReserve: CGFloat = 76

    private var layersPanelOverlay: some View {
        // ZStack must claim the full screen so its alignment(.topLeading) actually
        // pins the toggle button to the corner — without the maxWidth/maxHeight
        // frame the ZStack sizes to its content and the parent ZStack centers it.
        // SwiftUI's empty ZStack frame doesn't intercept taps on its own; the
        // dimmer view (only shown when the panel is open) is what catches outside
        // taps to dismiss.
        ZStack(alignment: .topLeading) {
            if showFavoritesPanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showFavoritesPanel = false
                        }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    layersPanelToggleButton
                    FavoritesPanel(
                        showTransitStops: $transitState.showTransitStops,
                        isPresented: $showFavoritesPanel,
                        mapStyle: $mapStyleOption,
                        onSelectRoute: { _ in
                            // Route drawing was removed with the planner; the
                            // chip just closes the panel until phase 2 rewires it.
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showFavoritesPanel = false
                            }
                        }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                .padding(.leading, 12)
                .padding(.top, 10)
                .padding(.bottom, Self.panelBottomReserve)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                layersPanelToggleButton
                    .padding(.leading, 12)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(10)
    }

    private var layersPanelToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.25)) {
                showFavoritesPanel.toggle()
            }
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

    // MARK: - Map

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                UserAnnotation()

                ForEach(filteredPlaces) { place in
                    let isDot = AnnotationSize(latitudeDelta: transitState.mapRegion?.span.latitudeDelta ?? 0.01) == .dot
                    Annotation(isDot ? "" : place.name, coordinate: place.coordinate) {
                        PlaceAnnotationView(
                            place: place,
                            layers: layers,
                            isOverlapMode: isOverlapMode,
                            zoomDelta: transitState.mapRegion?.span.latitudeDelta ?? 0.01
                        )
                        .onTapGesture {
                            if !isDot { viewModel.selectPlace(place) }
                        }
                    }
                }

                // Waypoint-path layers: render the connecting lines.
                ForEach(waypointPathRenderables, id: \.layer.id) { item in
                    let strokeColor = Color(hex: item.layer.colorHex) ?? .red
                    ForEach(Array(item.segments.enumerated()), id: \.offset) { _, segment in
                        MapPolyline(coordinates: segment)
                            .stroke(strokeColor, lineWidth: item.layer.lineWidth)
                    }
                }

                // Luas route lines (from GTFS shapes — accurate track geometry)
                if transitState.showTransitStops.contains(.luas) {
                    ForEach(Array(transitState.luasRedShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(TransitColors.luasRedLayer, lineWidth: 3)
                    }
                    ForEach(Array(transitState.luasGreenShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(TransitColors.layer(.luas), lineWidth: 3)
                    }
                }

                // DART lines (orange) — only the Dublin coastal line
                if transitState.showTransitStops.contains(.dart) {
                    ForEach(Array(transitState.dartShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(TransitColors.layer(.dart), lineWidth: 3)
                    }
                }

                // Irish Rail lines (purple) — Commuter, InterCity (non-DART)
                if transitState.showTransitStops.contains(.rail) {
                    ForEach(Array(transitState.railShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(TransitColors.layer(.rail), lineWidth: 3)
                    }
                }

                // Transit stop annotations (toggled layer)
                ForEach(transitState.visibleTransitStops) { stop in
                    let pinColor = pinColorForStop(stop)
                    let pin = TransitStopPin(stop: stop, zoomDelta: transitState.mapRegion?.span.latitudeDelta ?? 0.01, colorOverride: pinColor)
                    // Suppress title and tap target for dot-sized pins — they're too small
                    // to tap intentionally and steal taps from nearby visible annotations
                    Annotation(pin.isTappable ? stop.name : "", coordinate: stop.coordinate) {
                        if pin.isTappable {
                            pin.onTapGesture {
                                viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate, stopType: stop.type, stopCode: stop.stopCode, stopId: stop.id)
                            }
                        } else {
                            pin
                        }
                    }
                }
            }
            .mapStyle(currentMapStyle)
            // Intentionally NOT using .ignoresSafeArea(). Even when applied
            // to the Map alone, SwiftUI propagates the Map's larger frame
            // to its sibling overlays in a parent ZStack — which dragged
            // our layer-toggle button up behind the OS status bar. The
            // map respects the safe area; mapControls and overlays sit
            // where users expect them.
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { screenPoint in
                // Dismiss keyboard if searching
                if isSearchFocused {
                    isSearchFocused = false
                    searchState.clearSearch()
                    return
                }
                // If a sheet is already showing (from a previous tap), don't POI search
                if viewModel.activeSheet != nil { return }

                guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                poiSearchTask?.cancel()
                poiSearchTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, viewModel.activeSheet == nil else { return }
                    await searchPOI(at: coordinate)
                }
            }
            // Long-press to drop a pin at the press location.
            // SwiftUI's plain .onLongPressGesture has no location, so we sequence a
            // zero-distance DragGesture after a LongPressGesture to capture the screen
            // point, then convert it through the MapReader proxy.
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value,
                              let coord = proxy.convert(drag.location, from: .local)
                        else { return }
                        // Cancel any pending POI search from a near-simultaneous tap.
                        poiSearchTask?.cancel()
                        viewModel.startNewPlace(at: coord)
                    }
            )
            .onMapCameraChange(frequency: .onEnd) { context in
                transitState.mapRegion = context.region
                // Dismiss keyboard when user pans the map
                if isSearchFocused {
                    isSearchFocused = false
                }
            }
        }
    }

    // MARK: - Search Result Sections

    @ViewBuilder
    private var savedPlaceResults: some View {
        ForEach(searchState.placeSearchResults.prefix(5)) { place in
            Button(action: {
                searchState.showSearchResults = false
                searchState.searchText = ""
                cameraPosition = .region(MKCoordinateRegion(
                    center: place.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
                viewModel.selectPlace(place)
            }) {
                HStack(spacing: 10) {
                    // Layer color dots
                    ZStack {
                        let layerColors = (place.layers ?? []).prefix(2).compactMap { Color(hex: $0.colorHex) }
                        if let first = layerColors.first {
                            Circle().fill(first).frame(width: 28, height: 28)
                            Image(systemName: "mappin")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        } else {
                            Circle().fill(.gray.opacity(0.3)).frame(width: 28, height: 28)
                            Image(systemName: "mappin")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        let layerNames = (place.layers ?? []).map(\.name)
                        Text(layerNames.isEmpty ? "Saved place" : layerNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Saved")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var routeResults: some View {
        ForEach(searchState.routeSearchResults, id: \.routeId) { route in
            HStack(spacing: 10) {
                Button(action: {
                    // Route drawing was removed with the planner; phase 2
                    // rewires this. For now a tap just clears the search.
                    searchState.showSearchResults = false
                    searchState.searchText = ""
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: route.routeType == 0 ? "tram.fill" : (route.routeType == 2 ? "train.side.front.car" : "bus.fill"))
                            .foregroundStyle(.white)
                            .font(.caption.bold())
                            .frame(width: 28, height: 28)
                            .background(route.routeType == 0 ? .green : (route.routeType == 2 ? .orange : .blue))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Route \(route.routeName)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            if !route.longName.isEmpty {
                                Text(route.longName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "map.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Star toggle — pin/unpin this route to the layers panel quick-access strip.
                Button(action: { toggleFavoriteRoute(route) }) {
                    Image(systemName: isRouteFavorited(route.routeId) ? "star.fill" : "star")
                        .font(.subheadline)
                        .foregroundStyle(isRouteFavorited(route.routeId) ? .yellow : .secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
        }
    }

    private func isRouteFavorited(_ routeId: String) -> Bool {
        favoriteRoutes.contains { $0.routeId == routeId }
    }

    private func toggleFavoriteRoute(_ route: (routeId: String, routeName: String, longName: String, routeType: Int)) {
        if let existing = favoriteRoutes.first(where: { $0.routeId == route.routeId }) {
            modelContext.delete(existing)
            return
        }
        let nextOrder = (favoriteRoutes.map(\.sortOrder).max() ?? -1) + 1
        let fav = FavoriteTransitRoute(
            routeId: route.routeId,
            shortName: route.routeName,
            longName: route.longName,
            routeType: route.routeType,
            sortOrder: nextOrder
        )
        modelContext.insert(fav)
    }

    @ViewBuilder
    private var transitStopResults: some View {
        ForEach(searchState.transitSearchResults.prefix(5)) { stop in
            Button(action: {
                searchState.showSearchResults = false
                searchState.searchText = ""
                cameraPosition = .region(MKCoordinateRegion(
                    center: stop.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
                viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate, stopType: stop.type, stopCode: stop.stopCode, stopId: stop.id)
            }) {
                HStack(spacing: 10) {
                    Image(systemName: stop.type.systemImage)
                        .foregroundStyle(.white)
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(Color(hex: stop.type.colorHex) ?? .blue)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(stop.type.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(Color(hex: stop.type.colorHex) ?? .blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var poiResults: some View {
        // Separator before Apple Maps results
        if (!searchState.placeSearchResults.isEmpty || !searchState.transitSearchResults.isEmpty || !searchState.routeSearchResults.isEmpty) && !searchState.searchResults.isEmpty {
            Text("Nearby")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
        }

        // Apple Maps POI results
        ForEach(searchState.searchResults, id: \.self) { item in
            Button(action: {
                viewModel.showPOI(item)
                searchState.showSearchResults = false
                searchState.searchText = ""
                cameraPosition = .region(MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Unknown")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text([item.placemark.thoroughfare, item.placemark.locality]
                            .compactMap { $0 }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Settings (full hamburger menu)
            Button(action: { viewModel.showLayerSidebar() }) {
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
                    .focused($isSearchFocused)
                    .onChange(of: searchState.searchText) { _, _ in
                        searchState.debouncedSearch(places: places, transitStops: transitState.transitStops, userLocation: locationManager.userLocation)
                    }
                    .onSubmit {
                        isSearchFocused = false
                    }
                if !searchState.searchText.isEmpty {
                    Button(action: {
                        searchState.clearSearch()
                        isSearchFocused = false
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
                if !isSearchFocused {
                    Color.clear
                        .contentShape(Capsule())
                        .onTapGesture {
                            isSearchFocused = true
                        }
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

    // MARK: - POI Search

    // MARK: - Async Tasks (extracted from body to reduce type-checker complexity)

    @MainActor
    private func loadTransitData() async {
        // ARCHITECTURE — Two-phase load.
        //
        // The history of this function is a series of regressions where the user
        // saw an empty map (no stops or no lines) for some window — sometimes a
        // few seconds, sometimes seven days until the SQLite freshness window
        // expired. The recurring root cause was always the same shape: a slow
        // async step (downloading or re-parsing the 65MB GTFS ZIP, which can
        // take 30–60s) sat *between* the data we already had on disk and the
        // single point where we wrote it onto transitState.
        //
        // The fix is structural, not another patch:
        //
        //   PHASE 1 — Hydrate from disk caches synchronously *before* any await
        //             that could block. After Phase 1 the map is fully usable
        //             from whatever was cached on the previous successful launch.
        //             If every subsequent step in this function fails or hangs,
        //             the user still sees a working map.
        //
        //   PHASE 2 — Refresh from SQLite once the GTFS DB is loaded. Empty
        //             query results never overwrite a Phase 1 hit (so a partial
        //             SQLite parse can't wipe the map).
        //
        // MUST be @MainActor: writes @Observable state on transitState. Without
        // isolation Swift may schedule the final assignments off-main and
        // SwiftUI never observes the change.

        // ─── PHASE 1: Instant hydration from disk caches ──────────────────────
        // Both the stop JSON and the shape JSON are read synchronously (no
        // suspension). Map is populated within the first frame even if the
        // SQLite DB needs a 60s rebuild after this point.
        let loader = GTFSStopLoader()
        let stopsFromCache = await loader.loadStops()    // returns from JSON cache in ~100ms
        transitState.transitStops = stopsFromCache       // ← assign EARLY, before any slow await

        if let cached = TransitShapeCache.load() {
            transitState.luasRedShapeLines = cached.red
            transitState.luasGreenShapeLines = cached.green
            transitState.dartShapeLines = cached.dart
            transitState.railShapeLines = cached.rail
            transitState.luasRedStopIds = cached.luasRedStops
            transitState.luasGreenStopIds = cached.luasGreenStops
        }

        // ─── PHASE 2: Refresh from SQLite GTFS database ────────────────────────
        // This may block on a 30–60s re-parse the first time after install or
        // after the cached DB is rejected for being incomplete. Phase 1 already
        // populated the map, so the user is not staring at nothing.
        await GTFSScheduleService.shared.loadIfNeeded()
        let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()

        var reclassified = stopsFromCache
        if !classification.isEmpty {
            reclassified = stopsFromCache.map { stop in
                guard let typeStr = classification[stop.id],
                      let newType = TransitStop.TransitStopType(rawValue: typeStr),
                      stop.type != newType else { return stop }
                return TransitStop(id: stop.id, name: stop.name,
                                   latitude: stop.latitude, longitude: stop.longitude,
                                   type: newType, stopCode: stop.stopCode)
            }
        }
        let dedupedStops = Self.deduplicateLuasStops(reclassified, classifiedIds: Set(classification.keys))

        let luasShapes = await GTFSScheduleService.shared.luasShapesByLine()
        let luasStops = await GTFSScheduleService.shared.luasStopsByLine()
        let dart = await GTFSScheduleService.shared.shapeCoordinatesForDART()
        let rail = await GTFSScheduleService.shared.shapeCoordinatesForNonDartRail()

        // Single-frame batch refresh. Conditional overwrites are deliberate:
        // an empty SQL result (broken DB, mid-parse, partial download) MUST
        // NOT clobber the Phase 1 cache hit. The whole point of the two-phase
        // design is that Phase 2 can fail and the map keeps working.
        transitState.transitStops = dedupedStops
        if !luasShapes.red.isEmpty { transitState.luasRedShapeLines = luasShapes.red }
        if !luasShapes.green.isEmpty { transitState.luasGreenShapeLines = luasShapes.green }
        if !dart.isEmpty { transitState.dartShapeLines = dart }
        if !rail.isEmpty { transitState.railShapeLines = rail }
        if !luasStops.red.isEmpty || !luasStops.green.isEmpty {
            transitState.luasRedStopIds = luasStops.red
            transitState.luasGreenStopIds = luasStops.green
        }
        searchState.transitDataReady = true

        // Persist Phase 2's truth back to disk so the next launch's Phase 1 is
        // accurate. TransitShapeCache.save refuses empty snapshots so a fully
        // empty Phase 2 never wipes a good cache.
        TransitShapeCache.save(
            luasRed: transitState.luasRedShapeLines,
            luasGreen: transitState.luasGreenShapeLines,
            dart: transitState.dartShapeLines,
            rail: transitState.railShapeLines,
            luasRedStops: transitState.luasRedStopIds,
            luasGreenStops: transitState.luasGreenStopIds
        )
    }

    /// Extracted to a static function to avoid type-checker timeout in the .task closure.
    private static func deduplicateLuasStops(_ allStops: [TransitStop], classifiedIds: Set<String>) -> [TransitStop] {
        let luasStops = allStops.filter { $0.type == .luas }
            .sorted { classifiedIds.contains($0.id) && !classifiedIds.contains($1.id) }
        let nonLuas = allStops.filter { $0.type != .luas }
        var kept: [TransitStop] = []
        for stop in luasStops {
            let isDuplicate = kept.contains { existing in
                if WaypointGraph.meters(stop.coordinate, existing.coordinate) < 250 { return true }
                let a = stop.name.lowercased().replacingOccurrences(of: " luas", with: "")
                    .replacingOccurrences(of: " stop", with: "").trimmingCharacters(in: .whitespaces)
                let b = existing.name.lowercased().replacingOccurrences(of: " luas", with: "")
                    .replacingOccurrences(of: " stop", with: "").trimmingCharacters(in: .whitespaces)
                return a == b || a.contains(b) || b.contains(a)
            }
            if !isDuplicate { kept.append(stop) }
        }
        return nonLuas + kept
    }

    private func searchPOI(at coordinate: CLLocationCoordinate2D) async {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 50)
        let search = MKLocalSearch(request: request)
        if let response = try? await search.start(), let closest = response.mapItems.first {
            viewModel.showPOI(closest)
            return
        }

        let broadRequest = MKLocalPointsOfInterestRequest(center: coordinate, radius: 150)
        let broadSearch = MKLocalSearch(request: broadRequest)
        if let response = try? await broadSearch.start(),
           let closest = response.mapItems
            .sorted(by: {
                WaypointGraph.meters($0.placemark.coordinate, coordinate)
                    < WaypointGraph.meters($1.placemark.coordinate, coordinate)
            })
            .first {
            viewModel.showPOI(closest)
            return
        }

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
           let placemark = placemarks.first {
            let mkPlacemark = MKPlacemark(placemark: placemark)
            let mapItem = MKMapItem(placemark: mkPlacemark)
            mapItem.name = placemark.name ?? placemark.thoroughfare ?? "Tapped Location"
            viewModel.showPOI(mapItem)
        }
    }


    /// Determine pin color for a stop. Returns nil for the default (the
    /// stop type's `colorHex`); only overrides for Luas stops where the
    /// pin should match the LINE color (Red vs Green) rather than the
    /// generic Luas-green default. This is what gives the Red line stops
    /// red pins, matching DART (peach) / Rail (lilac) where pin = line.
    private func pinColorForStop(_ stop: TransitStop) -> Color? {
        guard stop.type == .luas else { return nil }
        if transitState.luasRedStopIds.contains(stop.id) {
            return TransitColors.luasRedPin
        }
        if transitState.luasGreenStopIds.contains(stop.id) {
            return TransitColors.luasGrnPin
        }
        return nil
    }
}
