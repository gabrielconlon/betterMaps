import SwiftUI
import SwiftData

struct LayerToggleSidebar: View {
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Binding var filterMode: FilterMode

    var body: some View {
        NavigationStack {
            List {
                Section("Filter Mode") {
                    Picker("Mode", selection: $filterMode) {
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

                Section("Layers") {
                    if layers.isEmpty {
                        Text("No layers yet. Create one in the Layers tab.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(layers) { layer in
                            LayerToggleRow(layer: layer)
                        }
                    }
                }

                if !layers.isEmpty {
                    Section {
                        Button("Show All") {
                            layers.forEach { $0.isVisible = true }
                        }
                        Button("Hide All") {
                            layers.forEach { $0.isVisible = false }
                        }
                    }
                }
            }
            .navigationTitle("Map Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

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
