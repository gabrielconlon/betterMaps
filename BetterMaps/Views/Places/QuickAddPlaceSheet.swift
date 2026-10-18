import SwiftUI
import SwiftData
import CoreLocation

/// Fast place capture after a long-press: the name fills itself from the
/// nearest POI or street address, and one 50 pt button saves into a smart
/// default layer (Tesler: the app absorbs the "which layer?" decision).
/// Other layers are one chip away; "More details…" opens the full form.
/// Saving where a place already exists (same name within 30 m, or anything
/// within 8 m) adds that place to the layer instead of duplicating it, so
/// overlaps can form.
struct QuickAddPlaceSheet: View {
    static let lastUsedLayerKey = "lastUsedLayerId"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Query private var places: [Place]
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
    @State private var isAddingLayer = false
    @State private var newLayerName = ""
    @State private var detent: PresentationDetent = .height(320)
    @FocusState private var isLayerNameFocused: Bool

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

    private var trimmedLayerName: String { newLayerName.trimmingCharacters(in: .whitespacesAndNewlines) }

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

            if isAddingLayer {
                newLayerRow
            }

            Button("More details…") { onMoreDetails(trimmedName, defaultLayerId) }
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(320), .medium], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(320)))
        .task {
            let found = await lookup(coordinate)
            isLookingUp = false
            if let found, name.isEmpty { name = found }
        }
    }

    /// Inline "new layer" entry (no alert): the place is saved into it.
    private var newLayerRow: some View {
        HStack(spacing: 8) {
            TextField("Layer name", text: $newLayerName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isLayerNameFocused)
                .onSubmit(addToNewLayer)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            Button("Add", action: addToNewLayer)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(trimmedLayerName.isEmpty)
        }
        .transition(.opacity)
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
                    withAnimation(.easeInOut(duration: 0.2)) { isAddingLayer = true }
                    detent = .medium
                    isLayerNameFocused = true
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
        if let layer {
            save(into: layer, createdLayer: false)
        } else {
            let created = Layer.insertDefault(named: SmartDefaultLayer.fallbackPlaceLayerName,
                                              kind: .places, symbolName: "star.fill",
                                              after: layers, in: modelContext)
            save(into: created, createdLayer: true)
        }
    }

    private func addToNewLayer() {
        let layerName = trimmedLayerName
        guard !layerName.isEmpty else { return }
        let layer = Layer.insertDefault(named: layerName, kind: .places, symbolName: "mappin",
                                        after: layers, in: modelContext)
        save(into: layer, createdLayer: true)
    }

    /// An existing saved place this capture stands for, if any.
    private var matchingPlace: Place? {
        let lites = PlaceMatcher.candidates(places.map(PlaceLite.init), layers: layers.map(LayerLite.init))
        guard let id = PlaceMatcher.match(name: trimmedName, coordinate: coordinate, among: lites) else { return nil }
        return places.first { $0.id == id }
    }

    /// Saves into `layer`: adds the matching existing place when there is
    /// one, else inserts a new place. Undo reverses exactly that, and also
    /// deletes a layer this quick add created if it is left empty.
    private func save(into layer: Layer, createdLayer: Bool) {
        let context = modelContext
        let message: String
        let undo: (@MainActor () -> Void)?

        if let existing = matchingPlace {
            let wasMember = existing.isMember(of: layer)
            existing.addMembership(layer)
            message = wasMember ? "Already in \(layer.name)" : "Added to \(layer.name)"
            if wasMember {
                undo = nil
            } else {
                undo = {
                    existing.removeMembership(layer)
                    Self.deleteIfEmpty(layer, created: createdLayer, in: context)
                    try? context.save()
                }
            }
        } else {
            let newPlace = Place(name: trimmedName.isEmpty ? "Dropped Pin" : trimmedName,
                                 latitude: coordinate.latitude,
                                 longitude: coordinate.longitude)
            context.insert(newPlace)
            newPlace.addMembership(layer)
            message = "Saved to \(layer.name)"
            undo = {
                context.delete(newPlace)
                Self.deleteIfEmpty(layer, created: createdLayer, in: context)
                try? context.save()
            }
        }
        try? context.save()
        lastUsedLayerIdRaw = layer.id.uuidString

        // Peak-end: the last thing the user sees is a confirmation they can undo.
        toastCenter?.show(message,
                          action: undo.map { ToastAction(label: "Undo", handler: $0) },
                          duration: .seconds(undo == nil ? 2 : 4))
        dismiss()
    }

    /// Undo of a quick add that created `layer` removes it again once empty.
    @MainActor
    private static func deleteIfEmpty(_ layer: Layer, created: Bool, in context: ModelContext) {
        guard created, !(layer.places ?? []).contains(where: { !$0.isDeleted }) else { return }
        context.delete(layer)
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
