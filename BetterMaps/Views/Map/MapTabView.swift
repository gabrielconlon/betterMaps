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
    @State private var placeSearchResults: [Place] = []
    @State private var transitSearchResults: [TransitStop] = []
    @State private var routeSearchResults: [(routeId: String, routeName: String, longName: String, routeType: Int)] = []
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
    @State private var luasRedShapeLines: [[CLLocationCoordinate2D]] = []
    @State private var luasGreenShapeLines: [[CLLocationCoordinate2D]] = []
    @State private var dartShapeLines: [[CLLocationCoordinate2D]] = [] // GTFS shapes for DART only
    @State private var railShapeLines: [[CLLocationCoordinate2D]] = [] // GTFS shapes for non-DART rail
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

    /// Transit stops filtered by active types and current map region.
    /// Visible at ALL zoom levels (dots at far zoom, full pins at close zoom),
    /// matching how custom layer places behave.
    /// At far zoom, rail/tram stops are prioritized over bus to avoid overwhelming the map.
    var visibleTransitStops: [TransitStop] {
        guard !showTransitStops.isEmpty, let region = mapRegion else { return [] }
        let latDelta = region.span.latitudeDelta

        let hasBusRouteSelected = !selectedBusRouteStopIds.isEmpty
        let wantsDart = showTransitStops.contains(.dart)
        let wantsRail = showTransitStops.contains(.rail)

        let filtered = transitStops
            .filter { stop in
                switch stop.type {
                case .dart:
                    guard wantsDart else { return false }
                case .rail, .suburban:
                    guard wantsRail else { return false }
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

        // Scale limits by zoom — dots are cheap but 14K bus stops would overwhelm
        if latDelta > 1.0 {
            // Country-wide: only rail/tram network, no bus
            return filtered.filter { $0.type != .bus }
        } else if latDelta > 0.3 {
            // Regional: all rail/tram + sampled bus
            let rail = filtered.filter { $0.type != .bus }
            let bus = Array(filtered.filter { $0.type == .bus }.prefix(150))
            return rail + bus
        } else {
            // City/neighborhood: generous limit
            return Array(filtered.prefix(500))
        }
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
                if showSearchResults && (!placeSearchResults.isEmpty || !transitSearchResults.isEmpty || !routeSearchResults.isEmpty || !searchResults.isEmpty) {
                    ScrollView {
                        VStack(spacing: 0) {
                            // Saved place matches
                            ForEach(placeSearchResults.prefix(5)) { place in
                                Button(action: {
                                    showSearchResults = false
                                    searchText = ""
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

                            // Transit route matches (e.g. "39A", "DART", "Green Line")
                            ForEach(routeSearchResults, id: \.routeId) { route in
                                Button(action: {
                                    showSearchResults = false
                                    searchText = ""
                                    Task { await selectBusRoute(routeId: route.routeId, routeName: route.routeName) }
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

                            // Transit stop matches (Luas, DART, bus stops)
                            ForEach(transitSearchResults.prefix(5)) { stop in
                                Button(action: {
                                    showSearchResults = false
                                    searchText = ""
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

                            // Separator before Apple Maps results
                            if (!placeSearchResults.isEmpty || !transitSearchResults.isEmpty || !routeSearchResults.isEmpty) && !searchResults.isEmpty {
                                Text("Nearby")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.08))
                            }

                            // Apple Maps POI results
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
                    .frame(maxHeight: 280)
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
            // GTFS is the single source of truth for all transit stops.
            // No hardcoded stops — GTFS IDs match stop_times for timetable queries,
            // and GTFS coordinates sit on the GTFS shape lines (no offset pins).
            let loader = GTFSStopLoader()
            transitStops = await loader.loadStops()

            // Load schedule database and reclassify stops by actual GTFS route data
            await GTFSScheduleService.shared.loadIfNeeded()
            let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()
            if !classification.isEmpty {
                transitStops = transitStops.map { stop in
                    guard let typeStr = classification[stop.id],
                          let newType = TransitStop.TransitStopType(rawValue: typeStr),
                          stop.type != newType else { return stop }
                    return TransitStop(id: stop.id, name: stop.name,
                                       latitude: stop.latitude, longitude: stop.longitude,
                                       type: newType, stopCode: stop.stopCode)
                }
            }

            // Deduplicate Luas stops — GTFS has multiple entries per station
            // (e.g. "Rialto" and "Rialto Luas") with coordinates 50-150m apart.
            // 200m is safe: closest adjacent Luas stops are ~300m apart in the city centre.
            // Sort so stops WITH timetable data (in classification result) come first,
            // ensuring the dedup keeps the useful stop and drops the dataless one.
            let classifiedIds = Set(classification.keys)
            let luasStops = transitStops.filter { $0.type == .luas }
                .sorted { classifiedIds.contains($0.id) && !classifiedIds.contains($1.id) }
            let nonLuas = transitStops.filter { $0.type != .luas }
            var keptLuas: [TransitStop] = []
            for stop in luasStops {
                if !isNearExistingStop(stop, in: keptLuas, thresholdMeters: 200) {
                    keptLuas.append(stop)
                }
            }
            transitStops = nonLuas + keptLuas

            // Load shapes from GTFS for all transit types
            let luasShapes = await GTFSScheduleService.shared.luasShapesByLine()
            luasRedShapeLines = luasShapes.red
            luasGreenShapeLines = luasShapes.green
            dartShapeLines = await GTFSScheduleService.shared.shapeCoordinatesForDART()
            railShapeLines = await GTFSScheduleService.shared.shapeCoordinatesForNonDartRail()
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
                showLiveTransit: $showLiveTransit,
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
                selectedTransitOption: $selectedTransitOption
            )
            .presentationDetents([.fraction(0.35), .medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .newPlace(let coordinate):
            PlaceFormView(coordinate: coordinate)

        case .transitArrivals(let name, let coord, let type, let stopCode):
            TransitArrivalsView(
                stationName: name,
                coordinate: coord,
                stopType: type,
                stopCode: stopCode,
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
                    let isDot = AnnotationSize(latitudeDelta: mapRegion?.span.latitudeDelta ?? 0.01) == .dot
                    Annotation(isDot ? "" : place.name, coordinate: place.coordinate) {
                        PlaceAnnotationView(
                            place: place,
                            layers: layers,
                            isOverlapMode: isOverlapMode,
                            zoomDelta: mapRegion?.span.latitudeDelta ?? 0.01
                        )
                        .onTapGesture {
                            if !isDot { viewModel.selectPlace(place) }
                        }
                    }
                }

                // Luas route lines (from GTFS shapes — accurate track geometry)
                if showTransitStops.contains(.luas) {
                    ForEach(Array(luasRedShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.red.opacity(0.6), lineWidth: 3)
                    }
                    ForEach(Array(luasGreenShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.green.opacity(0.6), lineWidth: 3)
                    }
                }

                // DART lines (orange) — only the Dublin coastal line
                if showTransitStops.contains(.dart) {
                    ForEach(Array(dartShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(.orange.opacity(0.6), lineWidth: 3)
                    }
                }

                // Irish Rail lines (purple) — Commuter, InterCity (non-DART)
                if showTransitStops.contains(.rail) {
                    ForEach(Array(railShapeLines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(Color(red: 0.69, green: 0.32, blue: 0.87).opacity(0.6), lineWidth: 3)
                    }
                }

                // Transit stop annotations (toggled layer)
                ForEach(visibleTransitStops) { stop in
                    let pinColor = pinColorForStop(stop)
                    let pin = TransitStopPin(stop: stop, zoomDelta: mapRegion?.span.latitudeDelta ?? 0.01, colorOverride: pinColor)
                    // Suppress title and tap target for dot-sized pins — they're too small
                    // to tap intentionally and steal taps from nearby visible annotations
                    Annotation(pin.isTappable ? stop.name : "", coordinate: stop.coordinate) {
                        if pin.isTappable {
                            pin.onTapGesture {
                                viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate, stopType: stop.type, stopCode: stop.stopCode)
                            }
                        } else {
                            pin
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

                    // Route labels at intervals along the line so one is always visible
                    // regardless of zoom level. Spaced at ~25% intervals.
                    let labelIndices = busRouteLabelIndices(count: selectedBusRouteCoords.count)
                    ForEach(labelIndices, id: \.self) { idx in
                        Annotation("", coordinate: selectedBusRouteCoords[idx], anchor: .center) {
                            Text(selectedBusRouteName)
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
                TextField("Search stops, routes, places...", text: $searchText, onEditingChanged: { editing in
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
                        placeSearchResults = []
                        transitSearchResults = []
                        routeSearchResults = []
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


    // MARK: - Bus Route Labels

    /// Indices along the bus route shape where labels should be placed.
    /// Returns ~4 evenly spaced indices so a label is always visible at any zoom.
    private func busRouteLabelIndices(count: Int) -> [Int] {
        guard count >= 2 else { return [] }
        if count < 8 { return [count / 2] }  // short routes: just midpoint
        let step = count / 4
        return [step, step * 2, step * 3]
    }

    // MARK: - Stop Deduplication

    /// Select a bus/tram/rail route from search results — loads shape and stop filter on map.
    @MainActor
    private func selectBusRoute(routeId: String, routeName: String) async {
        selectedBusRouteName = routeName
        async let shapeLoad = GTFSShapeService.shared.shapeCoordinates(forRouteId: routeId)
        async let stopsLoad = GTFSScheduleService.shared.stopIdsForRoute(routeId: routeId)
        let (coords, stopIds) = await (shapeLoad, stopsLoad)
        if let coords {
            selectedBusRouteCoords = coords
            // Zoom to fit the route
            if let first = coords.first {
                let lats = coords.map(\.latitude)
                let lons = coords.map(\.longitude)
                let center = CLLocationCoordinate2D(
                    latitude: (lats.min()! + lats.max()!) / 2,
                    longitude: (lons.min()! + lons.max()!) / 2
                )
                let span = MKCoordinateSpan(
                    latitudeDelta: (lats.max()! - lats.min()!) * 1.3,
                    longitudeDelta: (lons.max()! - lons.min()!) * 1.3
                )
                cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
            }
        }
        selectedBusRouteStopIds = stopIds
    }

    /// Check if a stop is within threshold meters of any existing stop (same type)
    private func isNearExistingStop(_ stop: TransitStop, in stops: [TransitStop], thresholdMeters: Double) -> Bool {
        let loc = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
        return stops.contains { existing in
            let existingLoc = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
            return existingLoc.distance(from: loc) < thresholdMeters
        }
    }

    // MARK: - Transit Toggle Persistence

    /// Determine pin color for a stop. Each type uses its own color —
    /// DART and Rail are independent toggles, no cross-showing.
    private func pinColorForStop(_ stop: TransitStop) -> Color? {
        return nil // use default color from stop type (orange=DART, purple=Rail, etc.)
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
        let query = searchText.trimmingCharacters(in: .whitespaces)

        // Search saved places (instant, in-memory)
        placeSearchResults = places
            .filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.tags.contains { $0.localizedCaseInsensitiveContains(query) } ||
                $0.notes.localizedCaseInsensitiveContains(query)
            }
            .sorted { a, b in
                let aPrefix = a.name.lowercased().hasPrefix(query.lowercased())
                let bPrefix = b.name.lowercased().hasPrefix(query.lowercased())
                if aPrefix != bPrefix { return aPrefix }
                return a.name < b.name
            }

        // Search transit stops by name (instant, in-memory)
        let lowerQuery = query.lowercased()
        transitSearchResults = transitStops
            .filter { $0.name.lowercased().contains(lowerQuery) }
            .sorted { a, b in
                // Exact prefix matches first, then alphabetical
                let aPrefix = a.name.lowercased().hasPrefix(lowerQuery)
                let bPrefix = b.name.lowercased().hasPrefix(lowerQuery)
                if aPrefix != bPrefix { return aPrefix }
                return a.name < b.name
            }

        // Search GTFS routes by name/number (instant, from SQLite)
        routeSearchResults = await GTFSScheduleService.shared.searchRoutes(query: query)

        // Search Apple Maps POIs (network call)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let userLocation = locationManager.userLocation {
            request.region = MKCoordinateRegion(
                center: userLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            searchResults = response.mapItems
        }
        showSearchResults = true
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
