import SwiftUI
import SwiftData

struct LayerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let layer: Layer?

    @State private var name: String = ""
    @State private var selectedColorHex: String = "#FF3B30"
    @State private var selectedSymbol: String = "mappin"
    @State private var showSaveToast = false

    var isEditing: Bool { layer != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Layer name", text: $name)
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
        } else {
            let newLayer = Layer(
                name: name.trimmingCharacters(in: .whitespaces),
                colorHex: selectedColorHex,
                symbolName: selectedSymbol
            )
            modelContext.insert(newLayer)
        }
        showSaveToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
    }
}
