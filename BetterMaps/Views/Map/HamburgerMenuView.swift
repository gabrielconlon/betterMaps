import SwiftUI
import SwiftData

struct HamburgerMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Binding var filterMode: FilterMode
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var mapStyleOption: MapStyleOption
    var onSelectPlace: ((Place) -> Void)?
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

    var body: some View {
        NavigationStack {
            List {
                Section("Places") {
                    NavigationLink(destination: PlaceSearchView(onSelectPlace: { place in
                        dismiss()
                        onSelectPlace?(place)
                    })) {
                        Label("All Saved Places", systemImage: "mappin.and.ellipse")
                    }
                }

                // MARK: - Map (layers, transit, style)
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
                    transitPinnableRow(.bus)
                    transitPinnableRow(.luas)
                    transitPinnableRow(.dart)
                    transitPinnableRow(.rail)

                    Button("Hide All Transit") {
                        showTransitStops = []
                    }
                    .font(.caption)

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
                }

                // MARK: - Services
                Section("Services") {
                    NavigationLink(destination: YelpKeySettingsView()) {
                        HStack {
                            Label("Yelp Integration", systemImage: "star.bubble")
                            Spacer()
                            Text(YelpService.isConfigured ? "Connected" : "Not Set")
                                .font(.caption)
                                .foregroundStyle(YelpService.isConfigured ? .green : .secondary)
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
    private func transitPinnableRow(_ type: TransitStop.TransitStopType) -> some View {
        let isFav = transitFavBinding(for: type)
        TransitTypeRow(type: type, showStops: $showTransitStops)
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

// MARK: - Layer Toggle Row

struct LayerToggleRow: View {
    @Bindable var layer: Layer

    var body: some View {
        Toggle(isOn: $layer.isVisible) {
            HStack(spacing: 10) {
                Image(systemName: layer.symbolName)
                    .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(layer.name)
                            .font(.body)
                        if layer.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                    Text("\(layer.places?.count ?? 0) places")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

// MARK: - Transit Type Row (explicit bindings, no ForEach capture issues)

struct TransitTypeRow: View {
    let type: TransitStop.TransitStopType
    @Binding var showStops: Set<TransitStop.TransitStopType>

    private var stopsOn: Binding<Bool> {
        Binding(
            get: { showStops.contains(type) },
            set: { if $0 { showStops.insert(type) } else { showStops.remove(type) } }
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
        }
        .padding(.vertical, 4)
    }
}
