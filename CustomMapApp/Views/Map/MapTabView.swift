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
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showSearchResults = false
    @State private var isSearchFocused = false
    @State private var activeWeatherOverlays: Set<WeatherOverlay> = []
    @State private var mapRegion: MKCoordinateRegion?
    @State private var transitStops: [TransitStop] = []
    @State private var showTransitStops: Set<TransitStop.TransitStopType> = []
    @State private var liveVehicles: [GTFSVehiclePosition] = []
    @State private var showLiveVehicles = false
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

    /// Transit stops filtered by active types and current map region (limit count for performance)
    var visibleTransitStops: [TransitStop] {
        guard !showTransitStops.isEmpty, let region = mapRegion else { return [] }
        let latDelta = region.span.latitudeDelta
        // Don't show at very far zoom
        guard latDelta < 0.15 else { return [] }
        // Filter by type and region
        return transitStops
            .filter { showTransitStops.contains($0.type) }
            .filter { stop in
                abs(stop.latitude - region.center.latitude) < latDelta &&
                abs(stop.longitude - region.center.longitude) < region.span.longitudeDelta
            }
            .prefix(200) // Performance cap
            .map { $0 }
    }

    /// Live vehicles filtered to current map region
    var visibleVehicles: [GTFSVehiclePosition] {
        guard let region = mapRegion else { return [] }
        return liveVehicles.filter { v in
            abs(v.latitude - region.center.latitude) < region.span.latitudeDelta &&
            abs(v.longitude - region.center.longitude) < region.span.longitudeDelta
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

                // Route clear
                if !routingVM.activeRoutes.isEmpty {
                    Button(action: { routingVM.clearRoutes() }) {
                        Label("Clear Routes", systemImage: "xmark.circle.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 4)
                }

                // Bottom bar: [hamburger] [search] [filter chips]
                bottomBar
            }
        }
        .onAppear {
            locationManager.requestPermission()
        }
        .task {
            // Load transit stops — Luas from hardcoded coordinates (fixed infrastructure)
            transitStops = LuasStopCoordinates.stops

            // Irish Rail stations from API (has coordinates)
            let railService = IrishRailService()
            let stations = await railService.fetchStations()
            for station in stations {
                let type: TransitStop.TransitStopType = station.type == .dart ? .dart : (station.type == .suburban ? .suburban : .rail)
                transitStops.append(TransitStop(id: station.id, name: station.name, latitude: station.latitude, longitude: station.longitude, type: type))
            }

            // GTFS bus stops (open data, no API key needed)
            let loader = GTFSStopLoader()
            let gtfsStops = await loader.loadStops()
            let existingIDs = Set(transitStops.map { $0.id })
            for stop in gtfsStops where !existingIDs.contains(stop.id) {
                transitStops.append(stop)
            }
        }
        .task(id: showLiveVehicles) {
            // Refresh live vehicles every 15 seconds when toggled on
            guard showLiveVehicles, NTATransitService.isConfigured else { return }
            let service = LiveVehicleService()
            var interval: Duration = .seconds(30)
            while !Task.isCancelled && showLiveVehicles {
                let vehicles = await service.fetchVehiclePositions()
                if vehicles.isEmpty {
                    // Backoff on failure/rate limit
                    interval = min(interval * 2, .seconds(120))
                } else {
                    liveVehicles = vehicles
                    interval = .seconds(30) // reset on success
                }
                try? await Task.sleep(for: interval)
            }
            liveVehicles = [] // clear when toggled off
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
                showLiveVehicles: $showLiveVehicles
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .routing(let context):
            RoutingPanelView(
                viewModel: routingVM,
                destinationName: context?.name ?? "",
                source: locationManager.userLocation,
                destination: context?.coordinate
            )
            .presentationDetents([.medium, .large])

        case .newPlace(let coordinate):
            PlaceFormView(coordinate: coordinate)

        case .transitArrivals(let name, let coord):
            TransitArrivalsView(stationName: name, coordinate: coord)
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))

        case .vehicleDetail(let vehicle):
            VehicleDetailView(vehicle: vehicle)
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

                // Transit stop annotations (toggled layer)
                ForEach(visibleTransitStops) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        TransitStopPin(stop: stop, zoomDelta: mapRegion?.span.latitudeDelta ?? 0.01)
                            .onTapGesture {
                                viewModel.showTransitArrivals(stationName: stop.name, coordinate: stop.coordinate)
                            }
                    }
                }

                // Live vehicle positions
                if showLiveVehicles {
                    ForEach(visibleVehicles) { vehicle in
                        Annotation(vehicle.routeShortName.isEmpty ? vehicle.routeId : vehicle.routeShortName, coordinate: vehicle.coordinate) {
                            VehicleDot(vehicle: vehicle)
                                .onTapGesture {
                                    viewModel.activeSheet = .vehicleDetail(vehicle)
                                }
                        }
                    }
                }

                ForEach(routingVM.activeRoutes) { routeResult in
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
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
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
            // Layers button
            Button(action: { viewModel.showLayerSidebar() }) {
                Image(systemName: "square.3.layers.3d")
                    .font(.body)
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
