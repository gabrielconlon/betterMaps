import SwiftUI
import SwiftData
import CoreLocation

/// Fast place capture after a long-press: the name fills itself from the
/// nearest POI or street address, and one 50 pt button saves into a smart
/// default layer (Tesler: the app absorbs the "which layer?" decision).
/// Other layers are one chip away; "More details…" opens the full form.
struct QuickAddPlaceSheet: View {
    static let lastUsedLayerKey = "lastUsedLayerId"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @AppStorage(QuickAddPlaceSheet.lastUsedLayerKey) private var lastUsedLayerIdRaw: String = ""

    let coordinate: CLLocationCoordinate2D
    /// Names the coordinate; nil keeps the field empty (never an error).
    let lookup: @Sendable (CLLocationCoordinate2D) async -> String?
    /// Opens the full place form with the typed/looked-up name and the
    /// default layer preselected.
    let onMoreDetails: (_ name: String, _ layerId: UUID?) -> Void

    @State private var name = ""
    @State private var isLookingUp = true
    @State private var pulse = false
    @State private var showNewLayerPrompt = false
    @State private var newLayerName = ""

    init(coordinate: CLLocationCoordinate2D,
         lookup: @escaping @Sendable (CLLocationCoordinate2D) async -> String? = { await PlaceLookupService.lookup($0) },
         onMoreDetails: @escaping (_ name: String, _ layerId: UUID?) -> Void) {
        self.coordinate = coordinate
        self.lookup = lookup
        self.onMoreDetails = onMoreDetails
    }

    // MARK: Derived

    private var placeLayers: [Layer] { layers.filter { $0.kind == .places } }

    private var defaultLayerId: UUID? {
        SmartDefaultLayer.placeLayer(in: layers.map(LayerLite.init),
                                     lastUsedLayerId: UUID(uuidString: lastUsedLayerIdRaw))
    }

    private var defaultLayer: Layer? {
        guard let id = defaultLayerId else { return nil }
        return placeLayers.first { $0.id == id }
    }

    private var otherLayers: [Layer] {
        placeLayers.filter { $0.id != defaultLayerId }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsSkeleton: Bool { isLookingUp && name.isEmpty }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dropped Pin")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            nameField

            Button { add(to: defaultLayer) } label: {
                Label("Add to \(defaultLayer?.name ?? SmartDefaultLayer.fallbackPlaceLayerName)",
                      systemImage: "plus.circle.fill")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))

            layerChips

            Button("More details…") { onMoreDetails(trimmedName, defaultLayerId) }
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(320), .medium])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(320)))
        .task {
            let found = await lookup(coordinate)
            isLookingUp = false
            if let found, name.isEmpty { name = found }
        }
        .alert("New layer", isPresented: $showNewLayerPrompt) {
            TextField("Layer name", text: $newLayerName)
                .textInputAutocapitalization(.words)
            Button("Add") { addToNewLayer() }
            Button("Cancel", role: .cancel) { newLayerName = "" }
        } message: {
            Text("The place is saved into the new layer.")
        }
    }

    private var nameField: some View {
        TextField(isLookingUp ? "" : "Name this spot", text: $name)
            .font(.title3.weight(.semibold))
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .onSubmit { add(to: defaultLayer) }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .overlay(alignment: .leading) {
                if showsSkeleton {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 170, height: 18)
                        .opacity(pulse ? 0.45 : 1)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                        .accessibilityLabel("Looking up the name")
                }
            }
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private var layerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(otherLayers) { layer in
                    Button { add(to: layer) } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: layer.colorHex) ?? .gray)
                                .frame(width: 10, height: 10)
                            Text(layer.name)
                                .lineLimit(1)
                        }
                        .chipStyle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add to \(layer.name)")
                }
                Button {
                    newLayerName = ""
                    showNewLayerPrompt = true
                } label: {
                    Label("New layer…", systemImage: "plus")
                        .chipStyle()
                }
                .buttonStyle(.plain)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Actions

    private func add(to layer: Layer?) {
        let target = layer ?? Layer.insertDefault(named: SmartDefaultLayer.fallbackPlaceLayerName,
                                                  kind: .places, symbolName: "star.fill",
                                                  after: layers, in: modelContext)
        save(into: target)
    }

    private func addToNewLayer() {
        let layerName = newLayerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !layerName.isEmpty else { return }
        let layer = Layer.insertDefault(named: layerName, kind: .places, symbolName: "mappin",
                                        after: layers, in: modelContext)
        save(into: layer)
    }

    private func save(into layer: Layer) {
        let place = Place(name: trimmedName.isEmpty ? "Dropped Pin" : trimmedName,
                          latitude: coordinate.latitude,
                          longitude: coordinate.longitude)
        modelContext.insert(place)
        if layer.places == nil { layer.places = [] }
        layer.places?.append(place)
        try? modelContext.save()
        lastUsedLayerIdRaw = layer.id.uuidString

        let context = modelContext
        // Peak-end: the last thing the user sees is a confirmation they can undo.
        toastCenter?.show("Saved to \(layer.name)",
                          action: ToastAction(label: "Undo") {
                              context.delete(place)
                              try? context.save()
                          },
                          duration: .seconds(4))
        dismiss()
    }
}

private extension View {
    func chipStyle() -> some View {
        self
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemFill), in: Capsule())
            .contentShape(Capsule())
    }
}
