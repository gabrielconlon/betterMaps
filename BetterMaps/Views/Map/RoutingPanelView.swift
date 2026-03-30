import SwiftUI
import SwiftData
import CoreLocation
import MapKit

struct RoutingPanelView: View {
    @Environment(\.modelContext) private var modelContext
    let viewModel: RoutingViewModel
    var originName: String = "Current Location"
    var destinationName: String = ""
    var source: CLLocationCoordinate2D?
    var destination: CLLocationCoordinate2D?

    @Binding var selectedRouteId: UUID?
    @Binding var selectedTransitOption: TransitRouteOption?
    @Binding var currentDetent: PresentationDetent
    var dismissAction: (() -> Void)?
    @State private var saved = false
    @State private var selectedRoute: RouteResult?
    @State private var showTimePicker = false
    @State private var showDeparturesSheet = false
    @State private var departuresStopName: String = ""
    @State private var departuresStopId: String = ""
    @State private var departuresCoordinate: CLLocationCoordinate2D = .init()
    @State private var departuresStopType: TransitStop.TransitStopType?

    // Custom origin
    @State private var customOrigin: CLLocationCoordinate2D?
    @State private var customOriginName: String?
    @State private var isEditingOrigin = false
    @State private var originSearchText = ""
    @State private var originSearchResults: [MKLocalSearchCompletion] = []
    @StateObject private var originCompleter = SearchCompleterDelegate()

    private var effectiveSource: CLLocationCoordinate2D? { customOrigin ?? source }
    private var effectiveOriginName: String { customOriginName ?? originName }

    private var isCustomDeparture: Bool { viewModel.customDepartureTime != nil }
    private var departureTime: Date { viewModel.customDepartureTime ?? Date() }

    var body: some View {
        if currentDetent == .fraction(0.08) {
            peekSummaryView
        } else {
            NavigationStack {
                Group {
                    if let transitOption = selectedTransitOption {
                        TransitTimelineView(
                            option: transitOption,
                            onTapRideLeg: { stopName, stopId, coordinate, mode in
                                departuresStopName = stopName
                                departuresStopId = stopId
                                departuresCoordinate = coordinate
                                departuresStopType = stopTypeFromLegMode(mode)
                                showDeparturesSheet = true
                            }
                        )
                            .sheet(isPresented: $showDeparturesSheet) {
                                TransitArrivalsView(
                                    stationName: departuresStopName,
                                    coordinate: departuresCoordinate,
                                    stopType: departuresStopType,
                                    stopCode: nil,
                                    stopId: departuresStopId
                                )
                                .presentationDetents([.medium, .large])
                            }
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: { selectedTransitOption = nil }) {
                                        Label("Routes", systemImage: "chevron.left")
                                    }
                                }
                            }
                    } else if let route = selectedRoute {
                        // Step-by-step view replaces the route list
                        NavigationStepsView(
                            routeResult: route,
                            destinationCoordinate: destination,
                            destinationName: destinationName
                        )
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: {
                                    selectedRoute = nil
                                    selectedRouteId = nil
                                }) {
                                    Label("Routes", systemImage: "chevron.left")
                                }
                            }
                        }
                        .onAppear { selectedRouteId = route.id }
                    } else {
                        routeListView
                    }
                }
                .toast(isPresented: $saved, message: "Routes saved for offline!")
                .sensoryFeedback(.success, trigger: saved)
            }
        }
    }

    private var peekSummaryView: some View {
        HStack {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .foregroundStyle(.blue)
            Text("\(viewModel.activeRoutes.count) routes")
                .font(.subheadline.bold())
            if let fastest = viewModel.activeRoutes.min(by: { $0.eta < $1.eta }) {
                Text("· \(Int(fastest.eta / 60)) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.clearRoutes()
                dismissAction?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { currentDetent = .fraction(0.35) }
        }
    }

    // MARK: - Origin Picker

    private var originRow: some View {
        VStack(spacing: 6) {
            if isEditingOrigin {
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("Search start location...", text: $originSearchText)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .onSubmit { searchOrigin() }
                            .onChange(of: originSearchText) { _, _ in
                                originCompleter.completer.queryFragment = originSearchText
                            }
                        Button(action: {
                            isEditingOrigin = false
                            originSearchText = ""
                            originSearchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Search results
                    if !originCompleter.results.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(originCompleter.results.prefix(5), id: \.self) { completion in
                                Button(action: { selectOriginCompletion(completion) }) {
                                    HStack {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundStyle(.blue)
                                            .font(.caption)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(completion.title)
                                                .font(.caption)
                                                .foregroundStyle(.primary)
                                            if !completion.subtitle.isEmpty {
                                                Text(completion.subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Reset to current location
                    if customOrigin != nil {
                        Button(action: resetOrigin) {
                            HStack(spacing: 4) {
                                Image(systemName: "location.fill")
                                Text("Use Current Location")
                            }
                            .font(.caption)
                            .foregroundStyle(.blue)
                        }
                    }
                }
            } else {
                Button(action: { isEditingOrigin = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: customOrigin != nil ? "mappin.circle.fill" : "location.fill")
                            .foregroundStyle(customOrigin != nil ? .blue : .green)
                            .font(.caption)
                        Text("From: \(effectiveOriginName)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func searchOrigin() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = originSearchText
        if let src = source {
            request.region = MKCoordinateRegion(center: src, latitudinalMeters: 20000, longitudinalMeters: 20000)
        }
        Task {
            let search = MKLocalSearch(request: request)
            if let response = try? await search.start(), let item = response.mapItems.first {
                customOrigin = item.placemark.coordinate
                customOriginName = item.name ?? item.placemark.title ?? "Selected Location"
                isEditingOrigin = false
                originSearchText = ""
                originSearchResults = []
                recalculateRoutes()
            }
        }
    }

    private func selectOriginCompletion(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        Task {
            let search = MKLocalSearch(request: request)
            if let response = try? await search.start(), let item = response.mapItems.first {
                customOrigin = item.placemark.coordinate
                customOriginName = completion.title
                isEditingOrigin = false
                originSearchText = ""
                originCompleter.results = []
                recalculateRoutes()
            }
        }
    }

    private func resetOrigin() {
        customOrigin = nil
        customOriginName = nil
        isEditingOrigin = false
        originSearchText = ""
        originCompleter.results = []
        recalculateRoutes()
    }

    private func recalculateRoutes() {
        guard let src = effectiveSource, let dest = destination else { return }
        let rules = (try? modelContext.fetch(FetchDescriptor<WeatherRule>())) ?? []
        viewModel.clearRoutes()
        selectedRouteId = nil
        selectedTransitOption = nil
        Task {
            await viewModel.calculateRoutes(
                from: src, to: dest,
                weatherRules: rules, context: modelContext,
                departureTime: departureTime,
                activeTransitLayers: viewModel.lastActiveTransitLayers
            )
        }
    }

    private var routeListView: some View {
        ScrollView {
            VStack(spacing: 8) {
                originRow

                if viewModel.isLoading && viewModel.activeRoutes.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding routes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                ForEach(viewModel.activeRoutes) { result in
                    RouteResultCard(result: result, onSelect: {
                        selectedRoute = result
                    })
                }

                if viewModel.isLoading && !viewModel.activeRoutes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading more routes...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                // Transit options (multi-modal: walk → bus/tram → walk)
                if !viewModel.transitOptions.isEmpty || viewModel.isLoadingTransit || viewModel.transitStatusMessage != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "tram.fill")
                                .foregroundStyle(.green)
                            Text("Transit Options")
                                .font(.subheadline.bold())
                            if viewModel.isLoadingTransit {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Spacer()
                            // Departure time picker
                            Button(action: { showTimePicker = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                    Text(isCustomDeparture ? departureTime.formatted(date: .omitted, time: .shortened) : "Now")
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isCustomDeparture ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
                                .foregroundStyle(isCustomDeparture ? .blue : .secondary)
                                .clipShape(Capsule())
                            }
                        }
                        .sheet(isPresented: $showTimePicker) {
                            NavigationStack {
                                VStack(spacing: 16) {
                                    DatePicker("Depart at", selection: Binding(
                                        get: { viewModel.customDepartureTime ?? Date() },
                                        set: { viewModel.customDepartureTime = $0 }
                                    ), in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                        .datePickerStyle(.graphical)
                                        .padding()
                                    Button("Leave Now") {
                                        viewModel.customDepartureTime = nil
                                        showTimePicker = false
                                        refreshTransit()
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .navigationTitle("Departure Time")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") {
                                            showTimePicker = false
                                            refreshTransit()
                                        }
                                    }
                                }
                            }
                            .presentationDetents([.medium])
                        }

                        if let status = viewModel.transitStatusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(viewModel.transitOptions) { option in
                            TransitOptionCard(option: option, onSelect: {
                                selectedTransitOption = option
                                selectedRouteId = nil  // Hide standard routes on map
                            })
                        }

                        if viewModel.transitOptions.isEmpty && !viewModel.isLoadingTransit {
                            Text("No transit routes found for this trip.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                // Failed routes
                if !viewModel.failedModes.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(viewModel.failedModes.keys), id: \.self) { mode in
                            HStack(spacing: 8) {
                                Image(systemName: mode.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(mode.displayName) unavailable")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.failedModes[mode] ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.top, 4)
                }

                // Save for offline
                if !viewModel.activeRoutes.isEmpty && !viewModel.isLoading {
                    Button(action: saveOffline) {
                        Label(
                            saved ? "Saved for offline!" : "Save for offline",
                            systemImage: saved ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(saved ? .green : .blue)
                    .disabled(saved)
                    .padding(.top, 4)
                }

                if !viewModel.isLoading && viewModel.activeRoutes.isEmpty {
                    ContentUnavailableView(
                        "No Routes",
                        systemImage: "map.fill",
                        description: Text(viewModel.errorMessage ?? "No routes available.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Routes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveOffline() {
        guard let src = effectiveSource, let destination else { return }
        viewModel.saveCurrentRoutes(
            context: modelContext,
            originName: effectiveOriginName,
            destinationName: destinationName,
            source: src,
            destination: destination
        )
        saved = true
    }

    private func refreshTransit() {
        guard let src = effectiveSource, let destination else { return }
        let rules = (try? modelContext.fetch(FetchDescriptor<WeatherRule>())) ?? []
        Task {
            await viewModel.calculateRoutes(
                from: src, to: destination,
                weatherRules: rules, context: modelContext,
                departureTime: departureTime,
                activeTransitLayers: viewModel.lastActiveTransitLayers
            )
        }
    }

    private func stopTypeFromLegMode(_ mode: TransitLegMode) -> TransitStop.TransitStopType {
        switch mode {
        case .bus:  return .bus
        case .luas: return .luas
        case .dart: return .dart
        case .rail: return .rail
        }
    }
}

// MARK: - MKLocalSearchCompleter Delegate

private class SearchCompleterDelegate: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    let completer = MKLocalSearchCompleter()
    @Published var results: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Bias results toward Dublin area
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 53.35, longitude: -6.26),
            latitudinalMeters: 50000, longitudinalMeters: 50000
        )
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
