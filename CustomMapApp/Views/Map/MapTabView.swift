import SwiftUI
import MapKit
import SwiftData

struct MapTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var layers: [Layer]
    @Query private var places: [Place]

    @State private var viewModel = MapViewModel()
    @State private var filterVM = LayerFilterViewModel()
    @State private var routingVM = RoutingViewModel()
    @State private var locationManager = LocationManager()

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedRouteId: UUID?
    @State private var selectedTransitOption: TransitRouteOption?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showSearchResults = false
    @State private var isSearchFocused = false
    @State private var activeWeatherOverlays: Set<WeatherOverlay> = []
    @State private var mapRegion: MKCoordinateRegion?
    @State private var transitStops: [TransitStop] = []
    @State private var showTransitStops: Set<TransitStop.TransitStopType> = []
    @State private var showLiveTransit: Set<TransitStop.TransitStopType> = []
    @State private var liveVehicles: [GTFSVehiclePosition] = []
    @State private var liveTrains: [IrishRailTrainPosition] = []
    @State private var selectedBusRouteCoords: [CLLocationCoordinate2D] = []
    @State private var selectedBusRouteName: String = ""
    @State private var selectedBusRouteStopIds: Set<String> = [] // stops on selected bus route
    @State private var showFavoritesPanel = false
    @State private var dartShapeLines: [[CLLocationCoordinate2D]] = [] // GTFS shapes for DART
    @AppStorage("savedTransitStops") private var savedTransitStops = ""
    @AppStorage("savedLiveTransit") private var savedLiveTransit = ""
    @AppStorage("openWeatherAPIKey") private var openWeatherAPIKey = ""

    var filteredPlaces: [Place] {
        filterVM.filteredPlaces(allPlaces: places, allLayers: layers)
    }

    var activeLayerCount: Int {
        layers.filter { $0.isVisible }.count
    }

    var isOverlapMode: Bool {
        filterVM.filterMode == .intersection && activeLayerCount > 1
    }

    /// Transit stops filtered by active types and current map region (limit count for performance).
    /// DART and Rail stations are shared infrastructure — show on either toggle.
    /// When a bus route is selected, only show stops on that route.
    var visibleTransitStops: [TransitStop] {
        guard !showTransitStops.isEmpty, let region = mapRegion else { return [] }
        let latDelta = region.span.latitudeDelta
        guard latDelta < 0.15 else { return [] }

        let hasBusRouteSelected = !selectedBusRouteStopIds.isEmpty
        let wantsDart = showTransitStops.contains(.dart)
        let wantsRail = showTransitStops.contains(.rail)

        return transitStops
            .filter { stop in
                switch stop.type {
                case .dart:
                    // DART stations also show when Rail is on (shared infrastructure)
                    guard wantsDart || wantsRail else { return false }
                case .rail, .suburban:
                    // Rail stations also show when DART is on (shared infrastructure)
                    guard wantsRail || wantsDart else { return false }
                case .bus:
                    guard showTransitStops.contains(.bus) else { return false }
                    if hasBusRouteSelected { return selectedBusRouteStopIds.contains(stop.id) }
                default:
                    guard showTransitStops.contains(stop.type) else { return false }
                }
                return true
            }
            .filter { stop in
                abs(stop.latitude - region.center.latitude) < latDelta &&
                abs(stop.longitude - region.center.longitude) < region.span.longitudeDelta
            }
            .prefix(200)
            .map { $0 }
    }

    /// Live NTA bus vehicles filtered to current map region
    var visibleVehicles: [GTFSVehiclePosition] {
        guard showLiveTransit.contains(.bus), let region = mapRegion else { return [] }
        return liveVehicles.filter { v in
            abs(v.latitude - region.center.latitude) < region.span.latitudeDelta &&
            abs(v.longitude - region.center.longitude) < region.span.longitudeDelta
        }
        .prefix(300)
        .map { $0 }
    }

    /// Live Irish Rail trains filtered to current map region
    var visibleTrains: [IrishRailTrainPosition] {
        let wantsDart = showLiveTransit.contains(.dart)
        let wantsRail = showLiveTransit.contains(.rail)
        guard wantsDart || wantsRail, let region = mapRegion else { return [] }
        return liveTrains.filter { train in
            let isDart = train.trainType.uppercased() == "DART"
            let typeMatch = (isDart && wantsDart) || (!isDart && wantsRail)
            let inRegion = abs(train.latitude - region.center.latitude) < region.span.latitudeDelta &&
                abs(train.longitude - region.center.longitude) < region.span.longitudeDelta
            return typeMatch && inRegion
        }
        .prefix(300)
        .map { $0 }
    }

    var body: some View {
        ZStack {
            // Map
            mapView

            // NOTE: Weather tile overlays require MKMapView (not SwiftUI Map).
            // Visual radar is blocked until the map layer is refactored.
            // Weather-based routing rules still work via WeatherKit.

            // Top-left layers button + panel
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showFavoritesPanel.toggle()
                            }
                        }) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.body)
                                .padding(10)
                                .background(showFavoritesPanel
                                    ? AnyShapeStyle(Color.blue.opacity(0.2))
                                    : AnyShapeStyle(.ultraThinMaterial))
                                .foregroundStyle(showFavoritesPanel ? .blue : .primary)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.1), radius: 2)
                        }

                        if showFavoritesPanel {
                            FavoritesPanel(
                                showTransitStops: $showTransitStops,
                                showLiveTransit: $showLiveTransit,
                                isPresented: $showFavoritesPanel
                            )
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.top, 10)
                    Spacer()
                }
                Spacer()
            }
            .zIndex(10)
            // Tap-outside dismiss for layers panel
            .background(
                showFavoritesPanel ?
                    Color.black.opacity(0.001) // Nearly invisible but tappable
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showFavoritesPanel = false
                            }
                        }
                    : nil
            )

            // UI overlays
            VStack(spacing: 0) {
                Spacer()

                // Search results above bottom bar
                if showSearchResults && !searchResults.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(searchResults, id: \.self) { item in
                                Button(action: {
                                    viewModel.showPOI(item)
                                    showSearchResults = false
                                    searchText = ""
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
                    }
                    .frame(maxHeight: 200)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // Route controls
                if !routingVM.activeRoutes.isEmpty {
                    HStack(spacing: 8) {
                        // Reopen routes panel
                        Button(action: {
                            viewModel.showRouting()
                        }) {
                            Label("Routes", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }

                        // Clear routes
                        Button(action: {
                            routingVM.clearRoutes()
                            selectedRouteId = nil
                            selectedTransitOption = nil
                        }) {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.bottom, 4)
                }

                // Bus route label + dismiss (show when route shape OR stop filter is active)
                if !selectedBusRouteCoords.isEmpty || !selectedBusRouteStopIds.isEmpty {
                    HStack(spacing: 8) {
                        Label("Route \(selectedBusRouteName)", systemImage: "bus.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())

                        Button(action: {
                            selectedBusRouteCoords = []
                            selectedBusRouteName = ""
                            selectedBusRouteStopIds = []
                        }) {
                            Label("Dismiss", systemImage: "xmark.circle.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.bottom, 4)
                }

                // Bottom bar: [settings] [search] [filter chips]
                bottomBar
            }
        }
        .onAppear {
            locationManager.requestPermission()
            // Restore persisted transit toggle states
            showTransitStops = deserializeTransitTypes(savedTransitStops)
            showLiveTransit = deserializeTransitTypes(savedLiveTransit)
        }
        .onChange(of: showTransitStops) { _, newValue in
            savedTransitStops = serializeTransitTypes(newValue)
        }
        .onChange(of: showLiveTransit) { _, newValue in
            savedLiveTransit = serializeTransitTypes(newValue)
        }
        .task {
            // Load transit stops from three sources, deduplicating aggressively.
            // Priority: Luas hardcoded > Irish Rail API > GTFS static feed
            var allStops: [TransitStop] = LuasStopCoordinates.stops

            // Irish Rail stations from API
            let railService = IrishRailService()
            let stations = await railService.fetchStations()
            for station in stations {
                let type: TransitStop.TransitStopType = station.type == .dart ? .dart : .rail
                let newStop = TransitStop(id: station.id, name: station.name, latitude: station.latitude, longitude: station.longitude, type: type)
                if !isNearExistingStop(newStop, in: allStops, thresholdMeters: 250) {
                    allStops.append(newStop)
                }
            }

            // GTFS stops — dedup ALL types by proximity (not just non-bus)
            let loader = GTFSStopLoader()
            let gtfsStops = await loader.loadStops()
            let existingIDs = Set(allStops.map { $0.id })
            for stop in gtfsStops where !existingIDs.contains(stop.id) {
                if !isNearExistingStop(stop, in: allStops, thresholdMeters: 150) {
                    allStops.append(stop)
                }
            }

            transitStops = allStops

            // Load rail route shapes from GTFS SQLite (route_type=2 = rail, includes DART)
            await GTFSScheduleService.shared.loadIfNeeded()
            await GTFSScheduleService.shared.logRouteTypes()
            dartShapeLines = await GTFSScheduleService.shared.shapeCoordinatesForRouteType(2)
        }
        .task(id: showLiveTransit) {
            // Debounce: wait 1 second after last toggle change before making API calls
            // This prevents rapid toggling from burning through rate limits
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let wantsBus = showLiveTransit.contains(.bus) && NTATransitService.isConfigured
            let wantsTrains = showLiveTransit.contains(.dart) || showLiveTransit.contains(.rail)
            guard wantsBus || wantsTrains else {
                liveVehicles = []
                liveTrains = []
                return
            }
            let vehicleService = LiveVehicleService()
            let railService = IrishRailService()
            var interval: Duration = .seconds(30)
            while !Task.isCancelled {
                async let busFetch: [GTFSVehiclePosition] = wantsBus ? vehicleService.fetchVehiclePositions() : []
                async let trainFetch: [IrishRailTrainPosition] = wantsTrains ? railService.fetchCurrentTrains() : []
                let (buses, trains) = await (busFetch, trainFetch)
                // Check cancellation before mutating state — prevents crash from mid-toggle updates
                guard !Task.isCancelled else { break }
                let anySuccess = !buses.isEmpty || !trains.isEmpty
                if wantsBus { liveVehicles = buses }
                if wantsTrains { liveTrains = trains }
                interval = anySuccess ? .seconds(30) : min(interval * 2, .seconds(120))
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
            }
            liveVehicles = []
            liveTrains = []
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(for: sheet)
        }
    }

    // MARK: - Sheet Router

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .placeDetail(let place):
            PlaceDetailSheet(
                place: place,
                onGetDirections: { dest in
                    viewModel.dismissSheet()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.showRouting(context: RouteContext(name: dest.name, coordinate: dest.coordinate))
                        Task { await calculateRoute(to: dest) }
                    }
                }
            )
            .presentationDetents([.fraction(0.25), .medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .poiDetail(let mapItem):
            POIAddToLayerView(
                mapItem: mapItem,
                onGetDirections: { item in
                    viewModel.dismissSheet()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.showRouting(context: RouteContext(name: item.name ?? "Destination", coordinate: item.placemark.coordinate))
                        Task { await calculateRouteToMapItem(item) }
                    }
                },
                onDismiss: { viewModel.dismissSheet() }
            )
            .presentationDetents([.fraction(0.25), .medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .layerSidebar:
            HamburgerMenuView(
                filterMode: $filterVM.filterMode,
                activeWeatherOverlays: $activeWeatherOverlays,
                bicyclePreference: $routingVM.bicyclePreference,
                showTransitStops: $showTransitStops,
                showLiveTransit: $showLiveTransit
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .routing(let context):
            RoutingPanelView(
                viewModel: routingVM,
                destinationName: context?.name ?? "",
                source: locationManager.userLocation,
                destination: context?.coordinate,
                selectedRouteId: $selectedRouteId,
                selectedTransitOption: $selectedTransitOption
            )
            .presentationDetents([.fraction(0.35), .medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .newPlace(let coordinate):
            PlaceFormView(coordinate: coordinate)

        case .transitArrivals(let name, let coord, let type):
            TransitArrivalsView(
                stationName: name,
                coordinate: coord,
                stopType: type,
                onSelectRoute: { routeId, routeName in
                    // User tapped a bus route — load and display its shape on the map
                    selectedBusRouteName = routeName
                    viewModel.activeSheet = nil  // Dismiss the arrivals sheet
                    Task {
                        async let shapeLoad = GTFSShapeService.shared.shapeCoordinates(forRouteId: routeId)
                        async let stopsLoad = GTFSScheduleService.shared.stopIdsForRoute(routeId: routeId)
                        let (coords, stopIds) = await (shapeLoad, stopsLoad)
                        if let coords {
                            selectedBusRouteCoords = coords
                        }
                        selectedBusRouteStopIds = stopIds
                    }
                }
            )
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .vehicleDetail(let vehicle):
            VehicleDetailView(vehicle: vehicle)
                .presentationDetents([.fraction(0.3), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.3)))

        case .trainDetail(let train):
            TrainDetailView(train: train)
                .presentationDetents([.fraction(0.3), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.3)))
        }
    }

    // MARK: - Map

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                UserAnnotation()

                ForEach(filteredPlaces) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        PlaceAnnotationView(
                            place: place,
                            layers: layers,
                            isOverlapMode: isOverlapMode,
                            zoomDelta: mapRegion?.span.latitudeDelta ?? 0.01
                        )
                        .onTapGesture {
                            viewModel.selectPlace(place)
                        }
                    }
                }

                // Luas route lines (always visible when Luas stops are on)
                if showTransitStops.contains(.luas) {
                    MapPolyline(coordinates: LuasStopCoordinates.lineCoordinates(LuasStopCoordinates.redLineMain))
                        .stroke(.red.opacity(0.6), lineWidth: 3)
                    MapPolyline(coordinates: LuasStopCoordinates.lineCoordinates(LuasStopCoordinates.redLineSaggart))
                        .stroke(.red.opacity(0.6), lineWidth: 3)
                    MapPolyline(coordinates: LuasStopCoordinates.lineCoordinates(LuasStopCoordinates.greenLine))
                        .stroke(.green.opacity(0.6), lineWidth: 3)
                }

                // DART route lines (from GTFS shapes — accurate track geometry)
                if showTransitStops.contains(.dart) || showTransitStops.contains(.rail) {
                    ForEach(Array(dartShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.orange.opacity(0.6), lineWidth: 3)
                    }
                }

                // Transit stop annotations (toggled layer)
                ForEach(visibleTransitStops) { stop in
                    let pinColor = pinColorForStop(stop)
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        TransitStopPin(stop: stop, zoomDelta: mapRegion?.span.latitudeDelta ?? 0.01, colorOverride: pinColor)
                            .onTapGesture {
                                viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate, stopType: stop.type)
                            }
                    }
                }

                // Live bus vehicle positions
                ForEach(visibleVehicles) { vehicle in
                    Annotation(vehicle.routeShortName.isEmpty ? "" : vehicle.routeShortName, coordinate: vehicle.coordinate) {
                        VehicleDot(vehicle: vehicle)
                            .onTapGesture {
                                viewModel.activeSheet = .vehicleDetail(vehicle)
                            }
                    }
                }

                // Live train positions
                ForEach(visibleTrains) { train in
                    Annotation(train.trainCode, coordinate: train.coordinate) {
                        TrainDot(train: train, zoomDelta: mapRegion?.span.latitudeDelta ?? 0.01)
                            .onTapGesture {
                                viewModel.activeSheet = .trainDetail(train)
                            }
                    }
                }

                // Routes — hide standard routes when a transit option is selected
                let routesToShow: [RouteResult] = {
                    if selectedTransitOption != nil { return [] }
                    if selectedRouteId != nil {
                        return routingVM.activeRoutes.filter { $0.id == selectedRouteId }
                    }
                    return routingVM.activeRoutes
                }()
                ForEach(routesToShow) { routeResult in
                    if let route = routeResult.route {
                        MapPolyline(route)
                            .stroke(
                                routeResult.mode.color,
                                lineWidth: routeResult.isPreferred ? 6 : 3
                            )
                    } else if let polyline = routeResult.cyclingPolyline {
                        MapPolyline(polyline)
                            .stroke(
                                routeResult.mode.color.opacity(0.8),
                                style: StrokeStyle(
                                    lineWidth: routeResult.isPreferred ? 6 : 3,
                                    dash: [8, 4]  // Dashed line for cycling
                                )
                            )
                    }
                }

                // Selected transit route legs (coordinates embedded in each leg)
                if let transitOption = selectedTransitOption {
                    ForEach(transitOption.legs) { leg in
                        switch leg {
                        case .walk(_, _, _, _, _, let fromCoord, let toCoord):
                            MapPolyline(coordinates: [fromCoord.clCoordinate, toCoord.clCoordinate])
                                .stroke(.green, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))

                        case .ride(_, _, _, _, _, _, _, _, let mode, _, _, let pathCoords):
                            let color: Color = {
                                switch mode {
                                case .bus: return .blue
                                case .luas: return .green
                                case .dart: return .orange
                                case .rail: return .purple
                                }
                            }()
                            if pathCoords.count >= 2 {
                                MapPolyline(coordinates: pathCoords.map { $0.clCoordinate })
                                    .stroke(color, lineWidth: 5)
                            }

                        case .transfer(_, _, _, _, let fromCoord, let toCoord):
                            MapPolyline(coordinates: [fromCoord.clCoordinate, toCoord.clCoordinate])
                                .stroke(.gray, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        }
                    }
                }

                // Selected bus route (from shapes.txt, shown when user taps a route)
                if selectedBusRouteCoords.count >= 2 {
                    MapPolyline(coordinates: selectedBusRouteCoords)
                        .stroke(.blue, lineWidth: 4)

                    // Route label at midpoint
                    let mid = selectedBusRouteCoords[selectedBusRouteCoords.count / 2]
                    Annotation(selectedBusRouteName, coordinate: mid) {
                        Text(selectedBusRouteName)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .shadow(radius: 2)
                    }

                    // Start and end markers
                    if let first = selectedBusRouteCoords.first {
                        Annotation("Start", coordinate: first) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    if let last = selectedBusRouteCoords.last {
                        Annotation("End", coordinate: last) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { screenPoint in
                // Dismiss keyboard if searching
                if isSearchFocused {
                    isSearchFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    return
                }
                // Clear any displayed bus route overlay
                if !selectedBusRouteCoords.isEmpty {
                    selectedBusRouteCoords = []
                    selectedBusRouteName = ""
                    return
                }
                // If a sheet is already showing (from a previous tap), don't POI search
                if viewModel.activeSheet != nil { return }

                guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                Task {
                    // Delay to let annotation taps fire first
                    try? await Task.sleep(for: .milliseconds(350))
                    // Only search if no sheet was opened by an annotation tap
                    guard viewModel.activeSheet == nil else { return }
                    await searchPOI(at: coordinate)
                }
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                guard let location = locationManager.userLocation else { return }
                viewModel.startNewPlace(at: location)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                mapRegion = context.region
                // Dismiss keyboard when user pans the map
                if isSearchFocused {
                    isSearchFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
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
                TextField("Search places...", text: $searchText, onEditingChanged: { editing in
                    isSearchFocused = editing
                })
                    .textFieldStyle(.plain)
                    .onSubmit {
                        isSearchFocused = false
                        Task { await performSearch() }
                    }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchResults = []
                        showSearchResults = false
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

    @MainActor
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
                let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                return loc.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude))
                    < loc.distance(from: CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude))
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


    // MARK: - Stop Deduplication

    /// Check if a stop is within threshold meters of any existing stop (same type)
    private func isNearExistingStop(_ stop: TransitStop, in stops: [TransitStop], thresholdMeters: Double) -> Bool {
        let loc = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
        return stops.contains { existing in
            let existingLoc = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
            return existingLoc.distance(from: loc) < thresholdMeters
        }
    }

    // MARK: - Transit Toggle Persistence

    /// Determine pin color for a stop, accounting for shared DART/Rail stations
    private func pinColorForStop(_ stop: TransitStop) -> Color? {
        let wantsDart = showTransitStops.contains(.dart)
        let wantsRail = showTransitStops.contains(.rail)

        // Shared DART/Rail station with both toggles on → combined color
        if (stop.type == .dart || stop.type == .rail || stop.type == .suburban) && wantsDart && wantsRail {
            return Color(red: 0.7, green: 0.4, blue: 0.9) // blended orange-purple
        }
        // DART station shown via Rail toggle only → purple
        if stop.type == .dart && !wantsDart && wantsRail {
            return .purple
        }
        // Rail station shown via DART toggle only → orange
        if (stop.type == .rail || stop.type == .suburban) && wantsDart && !wantsRail {
            return .orange
        }
        return nil // default color from stop type
    }

    private func serializeTransitTypes(_ types: Set<TransitStop.TransitStopType>) -> String {
        types.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    private func deserializeTransitTypes(_ string: String) -> Set<TransitStop.TransitStopType> {
        guard !string.isEmpty else { return [] }
        return Set(string.split(separator: ",").compactMap { TransitStop.TransitStopType(rawValue: String($0)) })
    }

    @MainActor
    private func performSearch() async {
        guard !searchText.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        if let userLocation = locationManager.userLocation {
            request.region = MKCoordinateRegion(
                center: userLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            searchResults = response.mapItems
            showSearchResults = true
        }
    }

    // MARK: - Routing

    @MainActor
    private func calculateRouteToMapItem(_ mapItem: MKMapItem) async {
        guard let userLocation = locationManager.userLocation else { return }
        let weatherRules = try? modelContext.fetch(FetchDescriptor<WeatherRule>())
        await routingVM.calculateRoutes(from: userLocation, to: mapItem.placemark.coordinate, weatherRules: weatherRules ?? [], context: modelContext)
    }

    @MainActor
    private func calculateRoute(to destination: Place) async {
        guard let userLocation = locationManager.userLocation else { return }
        let weatherRules = try? modelContext.fetch(FetchDescriptor<WeatherRule>())
        await routingVM.calculateRoutes(from: userLocation, to: destination.coordinate, weatherRules: weatherRules ?? [], context: modelContext)
    }
}
