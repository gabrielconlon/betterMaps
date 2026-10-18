import SwiftUI
import SwiftData
import UIKit

struct LayerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Optional screen-level toast host. When absent the form confirms with a haptic only.
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]

    let layer: Layer?

    @State private var name: String = ""
    @State private var selectedColorHex: String = "#FF3B30"
    @State private var selectedSymbol: String = "mappin"
    @State private var selectedKind: LayerKind = .places
    @State private var lineWidth: Double = 4.0
    @State private var showDiscardConfirm = false
    @State private var initialSnapshot: Snapshot? = nil

    var isEditing: Bool { layer != nil }

    /// A layer's type is fixed once it holds places or trails: switching a
    /// Places layer to Trails would turn saved places into trail points.
    private var canChangeKind: Bool { !(layer?.hasItems ?? false) }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var currentSnapshot: Snapshot {
        Snapshot(name: name, colorHex: selectedColorHex, symbol: selectedSymbol,
                 kind: selectedKind, lineWidth: lineWidth)
    }

    private var hasUnsavedEdits: Bool {
        guard let initialSnapshot else { return false }
        return initialSnapshot != currentSnapshot
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Layer name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    if canChangeKind {
                        Picker("Type", selection: $selectedKind) {
                            ForEach(LayerKind.allCases) { kind in
                                Label(kind.displayName, systemImage: kind.systemImage)
                                    .tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        LabeledContent("Type") {
                            Label(selectedKind.displayName, systemImage: selectedKind.systemImage)
                        }
                    }

                    Text(selectedKind.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Layer Type")
                } footer: {
                    if !canChangeKind {
                        Text("Type can't change once a layer has items.")
                    }
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
                        Text("Line")
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Color.layerPalette, id: \.hex) { item in
                            let isSelected = selectedColorHex == item.hex
                            Button {
                                selectedColorHex = item.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: item.hex) ?? .red)
                                    .frame(width: 40, height: 40)
                                    .overlay {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                                .font(.caption.bold())
                                        }
                                    }
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Color.layerSymbols, id: \.symbol) { item in
                            let isSelected = selectedSymbol == item.symbol
                            Button {
                                selectedSymbol = item.symbol
                            } label: {
                                Image(systemName: item.symbol)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        isSelected
                                            ? Color(hex: selectedColorHex)?.opacity(0.2) ?? Color.red.opacity(0.2)
                                            : Color.clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(
                                        isSelected
                                            ? Color(hex: selectedColorHex) ?? .red
                                            : .secondary
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(isEditing ? "Edit Layer" : "New Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { attemptCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            // Swipe-to-dismiss must not silently drop edits either.
            .interactiveDismissDisabled(hasUnsavedEdits)
            .confirmationDialog("Discard changes?",
                                isPresented: $showDiscardConfirm,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(isEditing ? "Your edits to this layer will be lost."
                               : "This layer hasn't been created.")
            }
            .onAppear {
                guard initialSnapshot == nil else { return }
                if let layer {
                    name = layer.name
                    selectedColorHex = layer.colorHex
                    selectedSymbol = layer.symbolName
                    selectedKind = layer.kind
                    lineWidth = layer.lineWidth
                }
                initialSnapshot = currentSnapshot
            }
        }
    }

    private func attemptCancel() {
        if hasUnsavedEdits {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func save() {
        let finalName = trimmedName
        guard !finalName.isEmpty else { return }
        if let layer {
            layer.name = finalName
            layer.colorHex = selectedColorHex
            layer.symbolName = selectedSymbol
            // Defensive: never retype a layer that already holds items.
            if !layer.hasItems { layer.kind = selectedKind }
            layer.lineWidth = lineWidth
        } else {
            let nextOrder = (allLayers.map(\.sortOrder).max() ?? -1) + 1
            let newLayer = Layer(
                name: finalName,
                colorHex: selectedColorHex,
                symbolName: selectedSymbol,
                sortOrder: nextOrder,
                kind: selectedKind,
                lineWidth: lineWidth
            )
            modelContext.insert(newLayer)
        }
        // Confirm immediately and close; no artificial delay.
        if let toastCenter {
            // The toast host plays the success haptic when it presents.
            toastCenter.show(isEditing ? "Layer updated" : "Layer created")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        dismiss()
    }

    private struct Snapshot: Equatable {
        var name: String
        var colorHex: String
        var symbol: String
        var kind: LayerKind
        var lineWidth: Double
    }
}
