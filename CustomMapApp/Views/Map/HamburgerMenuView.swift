import SwiftUI
import SwiftData

struct HamburgerMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Binding var filterMode: FilterMode
    @Binding var activeWeatherOverlays: Set<WeatherOverlay>
    @Binding var bicyclePreference: BicycleRoutePreference
    @AppStorage("openWeatherAPIKey") private var openWeatherAPIKey = ""
    @AppStorage("orsAPIKey") private var orsAPIKey = ""

    @Environment(\.modelContext) private var modelContext
    @State private var showLayerForm = false
    @State private var showEditLayerForm = false
    @State private var editingLayer: Layer?
    @State private var showSettings = false
    @State private var editingWeatherKey = ""

    var body: some View {
        NavigationStack {
            List {
                // MARK: - My Preferences
                Section("My Preferences") {
                    NavigationLink(destination: UserPreferencesView()) {
                        Label("Transport & Routing", systemImage: "person.fill")
                    }
                    NavigationLink(destination: WeatherRulesView()) {
                        Label("Weather Rules", systemImage: "cloud.sun")
                    }
                }

                // MARK: - Place Layers
                Section("Place Layers") {
                    if layers.isEmpty {
                        Text("No layers yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(layers) { layer in
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
                }

                // MARK: - Data Layers (Weather)
                Section("Weather Layers") {
                    ForEach(WeatherOverlay.allCases) { overlay in
                        HStack {
                            Label(overlay.displayName, systemImage: overlay.systemImage)
                            Spacer()
                            Text("Planned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Weather radar overlays require a map engine upgrade (SwiftUI Map → MKMapView). Weather-based routing rules are active now — configure them in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Transit toggles have moved to the Layers quick-panel (top-left map button)

                // MARK: - Cycling
                Section("Cycling Routes") {
                    Picker("Route Preference", selection: $bicyclePreference) {
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
                }

                // MARK: - Settings
                Section("Services") {

                    NavigationLink(destination: SavedRoutesView()) {
                        Label("Saved Routes (Offline)", systemImage: "arrow.down.circle")
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

                    // Yelp API key
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

                    // NTA Transit API key
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

                    // Cycling API key
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

                    // OpenWeatherMap API key
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
