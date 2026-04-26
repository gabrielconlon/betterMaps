import SwiftUI
import SwiftData

struct HamburgerMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Binding var filterMode: FilterMode
    @Binding var activeWeatherOverlays: Set<WeatherOverlay>
    @Binding var bicyclePreference: BicycleRoutePreference
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var showLiveTransit: Set<TransitStop.TransitStopType>
    @Binding var mapStyleOption: MapStyleOption
    var onSelectPlace: ((Place) -> Void)?
    @AppStorage("openWeatherAPIKey") private var openWeatherAPIKey = ""
    @AppStorage("orsAPIKey") private var orsAPIKey = ""
    @AppStorage("favTransitBus") private var favBus = true
    @AppStorage("favTransitLuas") private var favLuas = true
    @AppStorage("favTransitDart") private var favDart = true
    @AppStorage("favTransitRail") private var favRail = true
    @AppStorage("favMapStandard") private var favMapStandard = true
    @AppStorage("favMapMuted") private var favMapMuted = true
    @AppStorage("favMapSatellite") private var favMapSatellite = true
    @AppStorage("favMapHybrid") private var favMapHybrid = true

    @Environment(\.modelContext) private var modelContext
    @State private var showLayerForm = false
    @State private var showEditLayerForm = false
    @State private var editingLayer: Layer?
    @State private var showSettings = false
    @State private var editingWeatherKey = ""
    @State private var showRefreshConfirm = false
    /// Mirrors the AppStorage flag in ContentView. Setting this to false
    /// returns the user to GTFSSetupView which re-downloads the GTFS feed.
    @AppStorage("gtfsSetupComplete") private var gtfsSetupComplete = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - My Preferences (top-level for quick access)
                Section("My Preferences") {
                    NavigationLink(destination: UserPreferencesView()) {
                        Label("Transport & Routing", systemImage: "person.fill")
                    }
                    NavigationLink(destination: WeatherRulesView()) {
                        Label("Weather Rules", systemImage: "cloud.sun")
                    }
                    NavigationLink(destination: PlaceSearchView(onSelectPlace: { place in
                        dismiss()
                        onSelectPlace?(place)
                    })) {
                        Label("All Saved Places", systemImage: "mappin.and.ellipse")
                    }
                }

                // MARK: - Map (layers, transit, weather — nested)
                Section("Map") {
                    // Place Layers
                    NavigationLink(destination: layerManagementView) {
                        HStack {
                            Label("Place Layers", systemImage: "square.3.layers.3d")
                            Spacer()
                            Text("\(layers.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(action: { showLayerForm = true }) {
                        Label("New Layer", systemImage: "plus.circle")
                    }

                    if layers.filter({ $0.isVisible }).count > 1 {
                        Picker("Filter Mode", selection: $filterMode) {
                            ForEach(FilterMode.allCases, id: \.self) { mode in
                                Label(mode.rawValue, systemImage: mode.systemImage)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(filterMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Transit
                    transitPinnableRow(.bus, liveDisabled: !NTATransitService.isConfigured)
                    transitPinnableRow(.luas)
                    transitPinnableRow(.dart)
                    transitPinnableRow(.rail)

                    Button("Hide All Transit") {
                        showTransitStops = []
                        showLiveTransit = []
                    }
                    .font(.caption)

                    if !NTATransitService.isConfigured {
                        Text("Add NTA API key for live bus positions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Map Style
                    ForEach(MapStyleOption.allCases, id: \.self) { style in
                        HStack {
                            Image(systemName: style.icon)
                                .foregroundStyle(.primary)
                                .frame(width: 22)
                            Text(style.rawValue)
                                .font(.subheadline)
                            Spacer()
                            if mapStyleOption == style {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                            }
                            if isMapStyleFav(style) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { mapStyleOption = style }
                        .swipeActions(edge: .leading) {
                            Button {
                                toggleMapStyleFav(style)
                            } label: {
                                Label(
                                    isMapStyleFav(style) ? "Unpin" : "Pin to Layers",
                                    systemImage: isMapStyleFav(style) ? "star.slash" : "star.fill"
                                )
                            }
                            .tint(.yellow)
                        }
                    }

                    // Weather Layers
                    ForEach(WeatherOverlay.allCases) { overlay in
                        HStack {
                            Label(overlay.displayName, systemImage: overlay.systemImage)
                            Spacer()
                            Text("Planned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Weather radar overlays require a map engine upgrade (SwiftUI Map → MKMapView). Weather-based routing rules are active now — configure them above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Services (cycling, saved routes, API keys — nested)
                Section("Services") {
                    // Cycling Routes
                    Picker("Cycling Preference", selection: $bicyclePreference) {
                        ForEach(BicycleRoutePreference.allCases) { pref in
                            Label(pref.displayName, systemImage: pref.systemImage)
                                .tag(pref)
                        }
                    }

                    Text(bicyclePreference.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !BicycleRoutingService.isConfigured {
                        Text("Add an OpenRouteService API key below to enable cycling directions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink(destination: SavedRoutesView()) {
                        Label("Saved Routes (Offline)", systemImage: "arrow.down.circle")
                    }

                    // Transit data freshness + manual refresh.
                    HStack {
                        Label("Transit Schedule", systemImage: "tram.fill")
                        Spacer()
                        if let age = GTFSDatabase.ageDescription {
                            Text(age)
                                .font(.caption)
                                .foregroundStyle(GTFSDatabase.isFresh ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                        } else {
                            Text("Not loaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Per-source last-fetched timestamps. Pulled from
                    // APILogger.lastSuccessByService so each row shows the
                    // age of the most recent successful (or cached) hit
                    // for that data feed. Aligns with the architecture:
                    // user can see at a glance which feeds are live and
                    // which are stale.
                    let lastFetched = APILogger.shared.lastSuccessByService
                    perSourceRow("Bus (NTA)", systemImage: "bus.fill", date: lastFetched["NTA"])
                    perSourceRow("Irish Rail", systemImage: "train.side.front.car", date: lastFetched["Irish Rail"])
                    perSourceRow("Luas RTPI", systemImage: "tram.fill", date: lastFetched["Luas"])
                    Button(action: { showRefreshConfirm = true }) {
                        Label(
                            GTFSDatabase.isFresh ? "Refresh Transit Data" : "Refresh Now (Stale)",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(GTFSDatabase.isFresh ? Color.blue : Color.red)
                    }

                    NavigationLink(destination: APILogView()) {
                        HStack {
                            Label("API Logs", systemImage: "list.bullet.rectangle")
                            Spacer()
                            let failures = APILogger.shared.recentFailures
                            if failures > 0 {
                                Text("\(failures) errors")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    // Data usage
                    HStack {
                        Label("Data Used", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        Text(APILogger.shared.formattedDataUsage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reset") {
                            APILogger.shared.resetDataUsage()
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                    }

                    // API Keys
                    NavigationLink(destination: YelpKeySettingsView()) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Yelp Integration", systemImage: "star.bubble")
                                Spacer()
                                Text(YelpService.isConfigured ? "Connected" : "Not Set")
                                    .font(.caption)
                                    .foregroundStyle(YelpService.isConfigured ? .green : .secondary)
                            }
                            if let quota = APILogger.shared.quotas["Yelp"] {
                                Text("\(quota.remaining) of \(quota.limit) calls remaining · \(quota.staleness)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink(destination: NTAKeySettingsView()) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("TFI Transit (Bus/Rail)", systemImage: "bus.fill")
                                Spacer()
                                Text(NTATransitService.isConfigured ? "Connected" : "Not Set")
                                    .font(.caption)
                                    .foregroundColor(NTATransitService.isConfigured ? .green : .secondary)
                            }
                            if let quota = APILogger.shared.quotas["NTA"] {
                                Text("\(quota.remaining) of \(quota.limit) calls remaining · \(quota.staleness)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink(destination: ORSKeySettingsView()) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Cycling Directions", systemImage: "bicycle")
                                Spacer()
                                Text(BicycleRoutingService.isConfigured ? "Connected" : "Not Set")
                                    .font(.caption)
                                    .foregroundColor(BicycleRoutingService.isConfigured ? .green : .secondary)
                            }
                            if let quota = APILogger.shared.quotas["OpenRouteService"] {
                                Text("\(quota.remaining) of \(quota.limit) calls remaining · \(quota.staleness)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink(destination: OpenWeatherKeySettingsView()) {
                        HStack {
                            Label("Weather Layers", systemImage: "cloud.rain")
                            Spacer()
                            Text(openWeatherAPIKey.isEmpty ? "Not Set" : "Connected")
                                .font(.caption)
                                .foregroundColor(openWeatherAPIKey.isEmpty ? .secondary : .green)
                        }
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showLayerForm) {
                LayerFormView(layer: nil)
            }
            .sheet(isPresented: $showEditLayerForm) {
                if let layer = editingLayer {
                    LayerFormView(layer: layer)
                }
            }
            .confirmationDialog(
                "Refresh Transit Data?",
                isPresented: $showRefreshConfirm,
                titleVisibility: .visible
            ) {
                Button("Re-download GTFS Feed", role: .destructive) {
                    refreshTransitData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Forces a fresh download of the Irish transit schedule (~65 MB). The map keeps working from cached stops while the new data loads.")
            }
        }
    }

    /// Compact "X seconds ago" row for a live data source. nil date means
    /// the source has never been successfully fetched in this session.
    @ViewBuilder
    private func perSourceRow(_ label: String, systemImage: String, date: Date?) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
                .font(.subheadline)
            Spacer()
            if let date {
                Text(APILogger.relativeTimeString(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not fetched")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Reset the setup gate and clear caches that depend on the schedule.
    /// The user is dropped back into GTFSSetupView (already familiar) which
    /// re-downloads the GTFS feed and rebuilds SQLite. The stops cache stays
    /// so the map keeps showing pins through the refresh.
    private func refreshTransitData() {
        // Remove cached schedule + ZIP so loadIfNeeded re-downloads.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["gtfs_schedule.sqlite", "gtfs_all_cache.zip", "transit_graph.json", "gtfs_shapes_cache.json"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(name))
        }
        // Flip the gate so ContentView routes to GTFSSetupView.
        gtfsSetupComplete = false
        dismiss()
    }

    // MARK: - Layer Management View

    private var layerManagementView: some View {
        List {
            Section {
                Text("Drag the handles to reorder. This order is used in the slide-out panel and place pickers. Pinned layers always appear first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pinned") {
                let pinned = layers.filter { $0.isFavorite }
                if pinned.isEmpty {
                    Text("No pinned layers. Pin a layer to keep it at the top of the slide-out panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pinned) { layer in
                        layerManagementRow(layer)
                    }
                    .onMove { source, destination in
                        moveLayers(in: pinned, from: source, to: destination)
                    }
                }
            }

            Section("All Layers") {
                let unpinned = layers.filter { !$0.isFavorite }
                if unpinned.isEmpty {
                    Text("All your layers are pinned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unpinned) { layer in
                        layerManagementRow(layer)
                    }
                    .onMove { source, destination in
                        moveLayers(in: unpinned, from: source, to: destination)
                    }
                }
            }

            Section {
                Button(action: { showLayerForm = true }) {
                    Label("New Layer", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Place Layers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    @ViewBuilder
    private func layerManagementRow(_ layer: Layer) -> some View {
        NavigationLink(destination: LayerDetailView(layer: layer)) {
            LayerToggleRow(layer: layer)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                modelContext.delete(layer)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                editingLayer = layer
                showEditLayerForm = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
            Button {
                layer.isFavorite.toggle()
            } label: {
                Label(
                    layer.isFavorite ? "Unpin" : "Pin to Layers",
                    systemImage: layer.isFavorite ? "star.slash" : "star.fill"
                )
            }
            .tint(.yellow)
        }
    }

    /// Reorders the given slice (all-pinned or all-unpinned) by user gesture, then
    /// renumbers sortOrder across the full layer list. Pinned layers always come first,
    /// preserving each slice's independent user-defined order.
    private func moveLayers(in slice: [Layer], from source: IndexSet, to destination: Int) {
        var reordered = slice
        reordered.move(fromOffsets: source, toOffset: destination)
        let isPinnedSlice = slice.first?.isFavorite ?? false
        let pinnedOrder: [Layer] = isPinnedSlice ? reordered : layers.filter { $0.isFavorite }
        let unpinnedOrder: [Layer] = isPinnedSlice ? layers.filter { !$0.isFavorite } : reordered
        for (index, layer) in (pinnedOrder + unpinnedOrder).enumerated() {
            layer.sortOrder = index
        }
    }

    // MARK: - Transit Pinnable Row

    private func transitFavBinding(for type: TransitStop.TransitStopType) -> Binding<Bool> {
        switch type {
        case .bus: return $favBus
        case .luas: return $favLuas
        case .dart: return $favDart
        case .rail: return $favRail
        default: return .constant(true)
        }
    }

    @ViewBuilder
    private func transitPinnableRow(_ type: TransitStop.TransitStopType, liveDisabled: Bool = false) -> some View {
        let isFav = transitFavBinding(for: type)
        TransitTypeRow(type: type, showStops: $showTransitStops, showLive: $showLiveTransit, liveDisabled: liveDisabled)
            .swipeActions(edge: .leading) {
                Button {
                    isFav.wrappedValue.toggle()
                } label: {
                    Label(
                        isFav.wrappedValue ? "Unpin" : "Pin to Layers",
                        systemImage: isFav.wrappedValue ? "star.slash" : "star.fill"
                    )
                }
                .tint(.yellow)
            }
            .overlay(alignment: .topTrailing) {
                if isFav.wrappedValue {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                        .offset(x: -4, y: 4)
                }
            }
    }

    // MARK: - Map Style Favorites

    private func isMapStyleFav(_ style: MapStyleOption) -> Bool {
        switch style {
        case .standard: return favMapStandard
        case .muted: return favMapMuted
        case .satellite: return favMapSatellite
        case .hybrid: return favMapHybrid
        }
    }

    private func toggleMapStyleFav(_ style: MapStyleOption) {
        switch style {
        case .standard: favMapStandard.toggle()
        case .muted: favMapMuted.toggle()
        case .satellite: favMapSatellite.toggle()
        case .hybrid: favMapHybrid.toggle()
        }
    }
}

// MARK: - API Key Settings Views

struct YelpKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("yelpAPIKey") private var yelpAPIKey = ""
    @State private var editingKey = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("Yelp Fusion provides rich place details. Get a free key at yelp.com/developers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Free Tier Includes") {
                Label("Business hours & open/closed status", systemImage: "clock")
                    .font(.caption)
                Label("Up to 3 photos per place", systemImage: "photo")
                    .font(.caption)
                Label("Top 3 user reviews", systemImage: "star.bubble")
                    .font(.caption)
                Label("Rating & price range", systemImage: "dollarsign.circle")
                    .font(.caption)
                Label("500 API calls/day", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("API Key") {
                SecureField("Yelp API Key", text: $editingKey)
                Button(saved ? "Saved!" : "Save") {
                    yelpAPIKey = editingKey
                    YelpService.apiKey = editingKey
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                }
                .disabled(editingKey.isEmpty || saved)
            }
        }
        .navigationTitle("Yelp Integration")
        .onAppear { editingKey = yelpAPIKey }
    }
}

struct OpenWeatherKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openWeatherAPIKey") private var openWeatherAPIKey = ""
    @State private var editingKey = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("OpenWeatherMap provides weather radar overlays on the map. Get a free key at openweathermap.org/api")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Free Tier Includes") {
                Label("Precipitation radar", systemImage: "cloud.rain")
                    .font(.caption)
                Label("Cloud cover overlay", systemImage: "cloud.fill")
                    .font(.caption)
                Label("Wind speed overlay", systemImage: "wind")
                    .font(.caption)
                Label("Temperature heatmap", systemImage: "thermometer.medium")
                    .font(.caption)
                Label("Pressure overlay", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                Label("1,000 tile loads/day", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("API Key") {
                SecureField("OpenWeatherMap API Key", text: $editingKey)
                Button(saved ? "Saved!" : "Save") {
                    openWeatherAPIKey = editingKey
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                }
                .disabled(editingKey.isEmpty || saved)
            }
        }
        .navigationTitle("Weather Layers")
        .onAppear { editingKey = openWeatherAPIKey }
    }
}

struct ORSKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("orsAPIKey") private var orsAPIKey = ""
    @State private var editingKey = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("OpenRouteService provides cycling directions. Get a free key at openrouteservice.org")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Free Tier Includes") {
                Label("Cycling route directions", systemImage: "bicycle")
                    .font(.caption)
                Label("Quieter/safer route preference", systemImage: "leaf")
                    .font(.caption)
                Label("Turn-by-turn instructions", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.caption)
                Label("2,000 route requests/day", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Paid Tier Adds") {
                Label("Bike lane % and surface quality data", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Higher rate limits", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("API Key") {
                SecureField("OpenRouteService API Key", text: $editingKey)
                Button(saved ? "Saved!" : "Save") {
                    orsAPIKey = editingKey
                    BicycleRoutingService.apiKey = editingKey
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                }
                .disabled(editingKey.isEmpty || saved)
            }
        }
        .navigationTitle("Cycling Directions")
        .onAppear { editingKey = orsAPIKey }
    }
}

struct NTAKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ntaAPIKey") private var ntaAPIKey = ""
    @State private var editingKey = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("Transport for Ireland / NTA provides real-time bus, rail, and tram data across Ireland. Register free at developer.nationaltransport.ie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Free Tier Includes") {
                Label("Real-time bus arrivals (Dublin Bus, Bus Éireann, Go-Ahead)", systemImage: "bus.fill")
                    .font(.caption)
                Label("DART & commuter rail schedules", systemImage: "tram.fill")
                    .font(.caption)
                Label("Luas tram integration", systemImage: "lightrail.fill")
                    .font(.caption)
                Label("Service disruption alerts", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                Label("~1,000 requests/day", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("API Key") {
                SecureField("NTA API Key", text: $editingKey)
                Button(saved ? "Saved!" : "Save") {
                    ntaAPIKey = editingKey
                    NTATransitService.apiKey = editingKey
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                }
                .disabled(editingKey.isEmpty || saved)
            }
        }
        .navigationTitle("TFI Transit")
        .onAppear { editingKey = ntaAPIKey }
    }
}

// MARK: - Transit Type Row (explicit bindings, no ForEach capture issues)

struct TransitTypeRow: View {
    let type: TransitStop.TransitStopType
    @Binding var showStops: Set<TransitStop.TransitStopType>
    @Binding var showLive: Set<TransitStop.TransitStopType>
    var liveDisabled: Bool = false

    private var stopsOn: Binding<Bool> {
        Binding(
            get: { showStops.contains(type) },
            set: { if $0 { showStops.insert(type) } else { showStops.remove(type) } }
        )
    }

    private var liveOn: Binding<Bool> {
        Binding(
            get: { showLive.contains(type) },
            set: { if $0 { showLive.insert(type) } else { showLive.remove(type) } }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon + Name
            Image(systemName: type.systemImage)
                .foregroundColor(Color(hex: type.colorHex))
                .frame(width: 22)
            Text(type.displayName)
                .font(.subheadline.bold())
                .frame(width: 50, alignment: .leading)

            Spacer()

            // Stops toggle with label directly attached
            VStack(spacing: 2) {
                Text("Stops")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: stopsOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            // Live toggle with label directly attached
            VStack(spacing: 2) {
                Text("Live")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: liveOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(liveDisabled)
            }
        }
        .padding(.vertical, 4)
    }
}
