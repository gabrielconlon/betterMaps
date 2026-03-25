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
    @State private var showLayerSidebar = false
    @State private var showRoutingPanel = false

    var filteredPlaces: [Place] {
        filterVM.filteredPlaces(allPlaces: places, allLayers: layers)
    }

    var activeLayerCount: Int {
        layers.filter { $0.isVisible }.count
    }

    var body: some View {
        ZStack {
            mapView
            overlayControls
        }
        .onAppear {
            locationManager.requestPermission()
        }
        .sheet(isPresented: $viewModel.showPlaceDetail) {
            if let place = viewModel.selectedPlace {
                PlaceDetailSheet(
                    place: place,
                    onGetDirections: { destination in
                        viewModel.showPlaceDetail = false
                        showRoutingPanel = true
                        Task {
                            await calculateRoute(to: destination)
                        }
                    },
                    onEdit: { place in
                        viewModel.showPlaceDetail = false
                        viewModel.selectedPlace = place
                        viewModel.showEditPlace = true
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $viewModel.showEditPlace) {
            if let place = viewModel.selectedPlace {
                PlaceFormView(place: place)
            }
        }
        .sheet(isPresented: $viewModel.showNewPlaceForm) {
            PlaceFormView(coordinate: viewModel.longPressCoordinate)
        }
        .sheet(isPresented: $showLayerSidebar) {
            LayerToggleSidebar(filterMode: $filterVM.filterMode)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showRoutingPanel) {
            RoutingPanelView(viewModel: routingVM)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Map

    private var mapView: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(filteredPlaces) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    PlaceAnnotationView(place: place, layers: layers)
                        .onTapGesture {
                            viewModel.selectPlace(place)
                        }
                }
            }

            ForEach(routingVM.activeRoutes) { routeResult in
                MapPolyline(routeResult.route)
                    .stroke(
                        routeResult.mode.color,
                        lineWidth: routeResult.isPreferred ? 6 : 3
                    )
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            addPlaceAtCenter()
        }
    }

    // MARK: - Overlay Controls

    private var overlayControls: some View {
        VStack {
            HStack {
                // Layer toggle button
                Button(action: { showLayerSidebar.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.3.layers.3d")
                        if activeLayerCount > 0 {
                            Text("\(activeLayerCount)")
                                .font(.caption.bold())
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }

                Spacer()

                // Filter mode indicator
                if activeLayerCount > 1 {
                    Text(filterVM.filterMode.rawValue)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                Spacer()

                // Add place button
                Button(action: {
                    addPlaceAtCenter()
                }) {
                    Image(systemName: "plus")
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            // Route clear button
            if !routingVM.activeRoutes.isEmpty {
                Button(action: { routingVM.clearRoutes() }) {
                    Label("Clear Routes", systemImage: "xmark.circle.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Helpers

    private func addPlaceAtCenter() {
        guard let location = locationManager.userLocation else { return }
        viewModel.startNewPlace(at: location)
    }

    // MARK: - Routing

    @MainActor
    private func calculateRoute(to destination: Place) async {
        guard let userLocation = locationManager.userLocation else { return }
        let weatherRules = try? modelContext.fetch(FetchDescriptor<WeatherRule>())
        await routingVM.calculateRoutes(
            from: userLocation,
            to: destination.coordinate,
            weatherRules: weatherRules ?? []
        )
    }
}
