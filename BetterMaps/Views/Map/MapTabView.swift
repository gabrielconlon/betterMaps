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
    @State private var transitState = TransitMapState()
    @State private var searchState = SearchState()
    @FocusState private var isSearchFocused: Bool
    @State private var activeWeatherOverlays: Set<WeatherOverlay> = []
    @State private var showFavoritesPanel = false
    @State private var mapStyleOption: MapStyleOption = .standard
    @AppStorage("savedTransitStops") private var savedTransitStops = ""
    @AppStorage("savedLiveTransit") private var savedLiveTransit = ""
    @AppStorage("openWeatherAPIKey") private var openWeatherAPIKey = ""
    @AppStorage("hasSeenCoachMarks") private var hasSeenCoachMarks = false
    @State private var showCoachMarks = false
    @State private var routingDetent: PresentationDetent = .fraction(0.35)

    var filteredPlaces: [Place] {
        filterVM.filteredPlaces(allPlaces: places, allLayers: layers)
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

                        if showFavoritesPanel {
                            FavoritesPanel(
                                showTransitStops: $transitState.showTransitStops,
                                showLiveTransit: $transitState.showLiveTransit,
                                isPresented: $showFavoritesPanel,
                                mapStyle: $mapStyleOption
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

                // Dismiss button for selected bus route (route name is shown on the map line)
                if !transitState.selectedBusRouteCoords.isEmpty || !transitState.selectedBusRouteStopIds.isEmpty {
                    HStack(spacing: 8) {
                        Button(action: {
                            transitState.selectedBusRouteCoords = []
                            transitState.selectedBusRouteName = ""
                            transitState.selectedBusRouteStopIds = []
                        }) {
                            Label("Dismiss Route", systemImage: "xmark.circle.fill")
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

            if showCoachMarks {
                CoachMarkOverlay(isPresented: $showCoachMarks)
                    .zIndex(100)
            }
        }
        .onAppear {
            locationManager.requestPermission()
            // Restore persisted transit toggle states
            transitState.showTransitStops = transitState.deserializeTransitTypes(savedTransitStops)
            transitState.showLiveTransit = transitState.deserializeTransitTypes(savedLiveTransit)

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
        .onChange(of: transitState.showLiveTransit) { _, newValue in
            savedLiveTransit = transitState.serializeTransitTypes(newValue)
        }
        .onChange(of: showCoachMarks) { _, newValue in
            if !newValue {
                hasSeenCoachMarks = true
            }
        }
        .onChange(of: viewModel.activeSheet) { old, new in
            // Reset detent when routing sheet opens
            if let new, case .routing = new {
                routingDetent = .fraction(0.35)
            }
            // Clear routes when routing sheet is dismissed
            if let old, case .routing = old, new == nil {
                routingVM.clearRoutes()
                selectedRouteId = nil
                selectedTransitOption = nil
            }
        }
        .task {
            // All work happens in local variables — no @State/@Observable mutations
            // until the very end. This prevents 7+ intermediate body recomputes that
            // stall the main thread rendering MapPolylines and block touch events.

            // Step 1: Load stops into local var
            let loader = GTFSStopLoader()
            var allStops = await loader.loadStops()

            // Step 2: Load schedule database and reclassify
            await GTFSScheduleService.shared.loadIfNeeded()
            let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()
            if !classification.isEmpty {
                allStops = allStops.map { stop in
                    guard let typeStr = classification[stop.id],
                          let newType = TransitStop.TransitStopType(rawValue: typeStr),
                          stop.type != newType else { return stop }
                    return TransitStop(id: stop.id, name: stop.name,
                                       latitude: stop.latitude, longitude: stop.longitude,
                                       type: newType, stopCode: stop.stopCode)
                }
            }

            // Step 3: Luas dedup (on local var — no state mutation)
            let classifiedIds = Set(classification.keys)
            let luasStops = allStops.filter { $0.type == .luas }
                .sorted { classifiedIds.contains($0.id) && !classifiedIds.contains($1.id) }
            let nonLuas = allStops.filter { $0.type != .luas }
            var keptLuas: [TransitStop] = []
            for stop in luasStops {
                let isDuplicate = keptLuas.contains { kept in
                    let loc1 = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
                    let loc2 = CLLocation(latitude: kept.latitude, longitude: kept.longitude)
                    if loc1.distance(from: loc2) < 250 { return true }
                    let a = stop.name.lowercased().replacingOccurrences(of: " luas", with: "")
                        .replacingOccurrences(of: " stop", with: "").trimmingCharacters(in: .whitespaces)
                    let b = kept.name.lowercased().replacingOccurrences(of: " luas", with: "")
                        .replacingOccurrences(of: " stop", with: "").trimmingCharacters(in: .whitespaces)
                    return a == b || a.contains(b) || b.contains(a)
                }
                if !isDuplicate { keptLuas.append(stop) }
            }
            allStops = nonLuas + keptLuas

            // Step 4: Load ALL shapes into locals
            let luasShapes = await GTFSScheduleService.shared.luasShapesByLine()
            let dart = await GTFSScheduleService.shared.shapeCoordinatesForDART()
            let rail = await GTFSScheduleService.shared.shapeCoordinatesForNonDartRail()

            // Step 5: Single batch state update — ONE re-render instead of 7
            transitState.transitStops = allStops
            transitState.luasRedShapeLines = luasShapes.red
            transitState.luasGreenShapeLines = luasShapes.green
            transitState.dartShapeLines = dart
            transitState.railShapeLines = rail

            // Load cached transit graph for instant route planning (~50ms).
            // If no cache (first launch after install), build it.
            Task.detached(priority: .utility) {
                await TransitRoutePlanner.shared.headwayRouter.loadGraph()

                if await !TransitRoutePlanner.shared.headwayRouter.isReady {
                    let services = await GTFSScheduleService.shared.activeServiceIds(for: Date())
                    let stops = await GTFSStopLoader().loadStops()
                    let builder = TransitGraphBuilder()
                    let graph = await builder.build(
                        db: GTFSScheduleService.shared.database,
                        activeServices: services, allStops: stops
                    )
                    await TransitRoutePlanner.shared.headwayRouter.setGraph(graph)
                }
            }
        }
        .task(id: transitState.showLiveTransit) {
            // Debounce: wait 1 second after last toggle change before making API calls
            // This prevents rapid toggling from burning through rate limits
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let wantsBus = transitState.showLiveTransit.contains(.bus) && NTATransitService.isConfigured
            let wantsTrains = transitState.showLiveTransit.contains(.dart) || transitState.showLiveTransit.contains(.rail)
            guard wantsBus || wantsTrains else {
                transitState.liveVehicles = []
                transitState.liveTrains = []
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
                if wantsBus { transitState.liveVehicles = buses }
                if wantsTrains { transitState.liveTrains = trains }
                interval = anySuccess ? .seconds(30) : min(interval * 2, .seconds(120))
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
            }
            transitState.liveVehicles = []
            transitState.liveTrains = []
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
                showTransitStops: $transitState.showTransitStops,
                showLiveTransit: $transitState.showLiveTransit,
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

        case .routing(let context):
            RoutingPanelView(
                viewModel: routingVM,
                destinationName: context?.name ?? "",
                source: locationManager.userLocation,
                destination: context?.coordinate,
                selectedRouteId: $selectedRouteId,
                selectedTransitOption: $selectedTransitOption,
                currentDetent: $routingDetent
            )
            .presentationDetents([.fraction(0.08), .fraction(0.35), .medium, .large], selection: $routingDetent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .newPlace(let coordinate):
            PlaceFormView(coordinate: coordinate)

        case .transitArrivals(let name, let coord, let type, let stopCode, let stopId):
            TransitArrivalsView(
                stationName: name,
                coordinate: coord,
                stopType: type,
                stopCode: stopCode,
                stopId: stopId,
                onSelectRoute: { routeId, routeName in
                    // User tapped a bus route — load and display its shape on the map
                    transitState.selectedBusRouteName = routeName
                    viewModel.activeSheet = nil  // Dismiss the arrivals sheet
                    Task {
                        async let shapeLoad = GTFSShapeService.shared.shapeCoordinates(forRouteId: routeId)
                        async let stopsLoad = GTFSScheduleService.shared.stopIdsForRoute(routeId: routeId)
                        let (coords, stopIds) = await (shapeLoad, stopsLoad)
                        if let coords {
                            transitState.selectedBusRouteCoords = coords
                        }
                        transitState.selectedBusRouteStopIds = stopIds
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

                // Luas route lines (from GTFS shapes — accurate track geometry)
                if transitState.showTransitStops.contains(.luas) {
                    ForEach(Array(transitState.luasRedShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.red.opacity(0.6), lineWidth: 3)
                    }
                    ForEach(Array(transitState.luasGreenShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.green.opacity(0.6), lineWidth: 3)
                    }
                }

                // DART lines (orange) — only the Dublin coastal line
                if transitState.showTransitStops.contains(.dart) {
                    ForEach(Array(transitState.dartShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.orange.opacity(0.6), lineWidth: 3)
                    }
                }

                // Irish Rail lines (purple) — Commuter, InterCity (non-DART)
                if transitState.showTransitStops.contains(.rail) {
                    ForEach(Array(transitState.railShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(Color(red: 0.69, green: 0.32, blue: 0.87).opacity(0.6), lineWidth: 3)
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

                // Live bus vehicle positions
                ForEach(transitState.visibleVehicles) { vehicle in
                    Annotation(vehicle.routeShortName.isEmpty ? "" : vehicle.routeShortName, coordinate: vehicle.coordinate) {
                        VehicleDot(vehicle: vehicle)
                            .onTapGesture {
                                viewModel.activeSheet = .vehicleDetail(vehicle)
                            }
                    }
                }

                // Live train positions
                ForEach(transitState.visibleTrains) { train in
                    Annotation(train.trainCode, coordinate: train.coordinate) {
                        TrainDot(train: train, zoomDelta: transitState.mapRegion?.span.latitudeDelta ?? 0.01)
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
                if transitState.selectedBusRouteCoords.count >= 2 {
                    MapPolyline(coordinates: transitState.selectedBusRouteCoords)
                        .stroke(.blue, lineWidth: 4)

                    // Route labels at intervals along the line so one is always visible
                    // regardless of zoom level. Spaced at ~25% intervals.
                    let labelIndices = busRouteLabelIndices(count: transitState.selectedBusRouteCoords.count)
                    ForEach(labelIndices, id: \.self) { idx in
                        Annotation("", coordinate: transitState.selectedBusRouteCoords[idx], anchor: .center) {
                            Text(transitState.selectedBusRouteName)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.blue)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                                .shadow(radius: 2)
                        }
                    }

                    // Start and end markers
                    if let first = transitState.selectedBusRouteCoords.first {
                        Annotation("Start", coordinate: first) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    if let last = transitState.selectedBusRouteCoords.last {
                        Annotation("End", coordinate: last) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            }
            .mapStyle(currentMapStyle)
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { screenPoint in
                // Dismiss keyboard if searching
                if isSearchFocused {
                    isSearchFocused = false
                    return
                }
                // Clear any displayed bus route overlay
                if !transitState.selectedBusRouteCoords.isEmpty {
                    transitState.selectedBusRouteCoords = []
                    transitState.selectedBusRouteName = ""
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
            Button(action: {
                searchState.showSearchResults = false
                searchState.searchText = ""
                Task {
                    if let region = await transitState.selectBusRoute(routeId: route.routeId, routeName: route.routeName) {
                        cameraPosition = .region(region)
                    }
                }
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
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider()
        }
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
                viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate, stopType: stop.type)
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
                    .onSubmit {
                        isSearchFocused = false
                        Task { await searchState.performSearch(places: places, transitStops: transitState.transitStops, userLocation: locationManager.userLocation) }
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
                if !isSearchFocused {
                    Capsule()
                        .fill(Color.clear)
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


    // MARK: - Bus Route Labels

    /// Indices along the bus route shape where labels should be placed.
    /// Returns ~4 evenly spaced indices so a label is always visible at any zoom.
    private func busRouteLabelIndices(count: Int) -> [Int] {
        guard count >= 2 else { return [] }
        if count < 8 { return [count / 2] }  // short routes: just midpoint
        let step = count / 4
        return [step, step * 2, step * 3]
    }

    /// Determine pin color for a stop. Each type uses its own color —
    /// DART and Rail are independent toggles, no cross-showing.
    private func pinColorForStop(_ stop: TransitStop) -> Color? {
        return nil // use default color from stop type (orange=DART, purple=Rail, etc.)
    }

    // MARK: - Routing

    @MainActor
    private func calculateRouteToMapItem(_ mapItem: MKMapItem) async {
        guard let userLocation = locationManager.userLocation else { return }
        let weatherRules = try? modelContext.fetch(FetchDescriptor<WeatherRule>())
        await routingVM.calculateRoutes(from: userLocation, to: mapItem.placemark.coordinate, weatherRules: weatherRules ?? [], context: modelContext, activeTransitLayers: transitState.showTransitStops)
    }

    @MainActor
    private func calculateRoute(to destination: Place) async {
        guard let userLocation = locationManager.userLocation else { return }
        let weatherRules = try? modelContext.fetch(FetchDescriptor<WeatherRule>())
        await routingVM.calculateRoutes(from: userLocation, to: destination.coordinate, weatherRules: weatherRules ?? [], context: modelContext, activeTransitLayers: transitState.showTransitStops)
    }
}
