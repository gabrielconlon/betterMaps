import SwiftUI
import SwiftData

struct LayerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]

    let layer: Layer?

    @State private var name: String = ""
    @State private var selectedColorHex: String = "#FF3B30"
    @State private var selectedSymbol: String = "mappin"
    @State private var selectedKind: LayerKind = .places
    @State private var lineWidth: Double = 4.0
    @State private var showSaveToast = false

    var isEditing: Bool { layer != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Layer name", text: $name)
                }

                Section {
                    Picker("Type", selection: $selectedKind) {
                        ForEach(LayerKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(selectedKind.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Layer Type")
                }

                if selectedKind == .waypointPath {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Line width")
                                Spacer()
                                Text(String(format: "%.0f pt", lineWidth))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $lineWidth, in: 2...10, step: 1)
                                .tint(Color(hex: selectedColorHex) ?? .red)
                        }
                    } header: {
                        Text("Path Style")
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Color.layerPalette, id: \.hex) { item in
                            Circle()
                                .fill(Color(hex: item.hex) ?? .red)
                                .frame(width: 40, height: 40)
                                .overlay {
                                    if selectedColorHex == item.hex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.caption.bold())
                                    }
                                }
                                .onTapGesture {
                                    selectedColorHex = item.hex
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Color.layerSymbols, id: \.symbol) { item in
                            Image(systemName: item.symbol)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(
                                    selectedSymbol == item.symbol
                                        ? Color(hex: selectedColorHex)?.opacity(0.2) ?? Color.red.opacity(0.2)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(
                                    selectedSymbol == item.symbol
                                        ? Color(hex: selectedColorHex) ?? .red
                                        : .secondary
                                )
                                .onTapGesture {
                                    selectedSymbol = item.symbol
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(isEditing ? "Edit Layer" : "New Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let layer {
                    name = layer.name
                    selectedColorHex = layer.colorHex
                    selectedSymbol = layer.symbolName
                    selectedKind = layer.kind
                    lineWidth = layer.lineWidth
                }
            }
            .toast(isPresented: $showSaveToast, message: layer != nil ? "Layer updated!" : "Layer created!")
            .sensoryFeedback(.success, trigger: showSaveToast)
        }
    }

    private func save() {
        if let layer {
            layer.name = name.trimmingCharacters(in: .whitespaces)
            layer.colorHex = selectedColorHex
            layer.symbolName = selectedSymbol
            layer.kind = selectedKind
            layer.lineWidth = lineWidth
        } else {
            let nextOrder = (allLayers.map(\.sortOrder).max() ?? -1) + 1
            let newLayer = Layer(
                name: name.trimmingCharacters(in: .whitespaces),
                colorHex: selectedColorHex,
                symbolName: selectedSymbol,
                sortOrder: nextOrder,
                kind: selectedKind,
                lineWidth: lineWidth
            )
            modelContext.insert(newLayer)
        }
        showSaveToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
    }
}
