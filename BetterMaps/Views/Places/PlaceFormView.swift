import SwiftUI
import SwiftData
import MapKit
import UIKit

struct PlaceFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Optional screen-level toast host. When absent the form confirms with a haptic only.
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]
    @AppStorage(QuickAddPlaceSheet.lastUsedLayerKey) private var lastUsedLayerIdRaw: String = ""

    let place: Place?
    let initialCoordinate: CLLocationCoordinate2D?
    /// Where the caller's map was looking; used only when there is no place and no
    /// explicit coordinate. When both are nil the pin starts unset and the user taps.
    let mapCenter: CLLocationCoordinate2D?
    let targetLayer: Layer?
    /// Prefills for a new place (from the quick-add sheet's "More details…").
    let initialName: String?
    let preselectedLayerId: UUID?

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var rating: Int = 0
    @State private var hoursInfo: String = ""
    @State private var tagsText: String = ""
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var photoData: [Data] = []
    @State private var selectedLayerIds: Set<UUID> = []
    @State private var showDiscardConfirm = false
    @State private var showExactCoordinates = false
    @State private var initialSnapshot: Snapshot? = nil

    var isEditing: Bool { place != nil }

    init(place: Place? = nil,
         coordinate: CLLocationCoordinate2D? = nil,
         layer: Layer? = nil,
         mapCenter: CLLocationCoordinate2D? = nil,
         name: String? = nil,
         preselectedLayerId: UUID? = nil) {
        self.place = place
        self.initialCoordinate = coordinate
        self.targetLayer = layer
        self.mapCenter = mapCenter
        self.initialName = name
        self.preselectedLayerId = preselectedLayerId
    }

    // MARK: Derived state

    private var pinCoordinate: CLLocationCoordinate2D? {
        CoordinateText.validated(latitude: latitude, longitude: longitude)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Place layers only: a saved place never goes into a trail layer here.
    private var placeKindLayers: [Layer] { allLayers.filter { $0.kind == .places } }

    /// The chips show whenever there's no fixed target layer, new or editing.
    private var showsLayerChips: Bool { targetLayer == nil && !placeKindLayers.isEmpty }

    /// Trail memberships keep an edited place alive with no place layer ticked.
    private var hasTrailMembership: Bool {
        (place?.layers ?? []).contains { $0.kind == .waypointPath }
    }

    private var hasLayerChoice: Bool {
        !showsLayerChips || !selectedLayerIds.isEmpty || hasTrailMembership
    }

    private var canSave: Bool { !trimmedName.isEmpty && pinCoordinate != nil && hasLayerChoice }

    private var currentSnapshot: Snapshot {
        Snapshot(name: name, notes: notes, rating: rating, hoursInfo: hoursInfo,
                 tagsText: tagsText, latitude: latitude, longitude: longitude,
                 photoData: photoData, selectedLayerIds: selectedLayerIds)
    }

    private var hasUnsavedEdits: Bool {
        guard let initialSnapshot else { return false }
        return initialSnapshot != currentSnapshot
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Place name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    miniMap
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                    DisclosureGroup("Exact coordinates", isExpanded: $showExactCoordinates) {
                        coordinateField("Latitude", value: $latitude)
                        coordinateField("Longitude", value: $longitude)
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first,
                                  let parsed = CoordinateText.parse(text) else { return }
                            Task { @MainActor in setPin(parsed, recenter: true) }
                        }
                        .labelStyle(.titleAndIcon)
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text(pinCoordinate == nil
                         ? "Tap the map to drop the pin."
                         : "Tap the map to move the pin.")
                }

                Section("Rating") {
                    RatingView(rating: $rating)
                }

                Section("Details") {
                    TextField("Hours (e.g., Mon-Fri 9-5)", text: $hoursInfo)
                    TextField("Tags (comma separated)", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                Section("Photos") {
                    PhotoPickerView(photoData: $photoData)
                }

                // Layers — new or editing, so one place can be in several
                // layers (the overlaps the map highlights).
                if showsLayerChips {
                    Section {
                        LayerMembershipChips(layers: placeKindLayers, selected: selectedLayerIds) { layer in
                            if selectedLayerIds.contains(layer.id) {
                                selectedLayerIds.remove(layer.id)
                            } else {
                                selectedLayerIds.insert(layer.id)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Layers")
                    } footer: {
                        Text("Pick one or more.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Place" : "New Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { attemptCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
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
                Text(isEditing ? "Your edits to this place will be lost."
                               : "This place hasn't been saved.")
            }
            .onAppear(perform: hydrate)
        }
    }

    // MARK: Subviews

    private var miniMap: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if let pin = pinCoordinate {
                    Marker(trimmedName.isEmpty ? "New Place" : trimmedName, coordinate: pin)
                }
                UserAnnotation()
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if let tapped = proxy.convert(point, from: .local) {
                    setPin(tapped, recenter: false)
                }
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Location map")
        .accessibilityHint("Tap to place the pin. Exact coordinates can be entered below.")
    }

    private func coordinateField(_ label: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            TextField(label,
                      value: value,
                      format: .number.precision(.fractionLength(5)).grouping(.never))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .onSubmit { recenterOnPin() }
        }
    }

    // MARK: Actions

    private func hydrate() {
        // onAppear can fire again after a child sheet (photo picker) closes.
        guard initialSnapshot == nil else { return }

        if let place {
            name = place.name
            notes = place.notes
            rating = place.rating
            hoursInfo = place.hoursInfo
            tagsText = place.tags.joined(separator: ", ")
            latitude = place.latitude
            longitude = place.longitude
            photoData = place.photoData
            selectedLayerIds = Set((place.layers ?? []).filter { $0.kind == .places }.map(\.id))
        } else {
            if let start = initialCoordinate ?? mapCenter {
                latitude = start.latitude
                longitude = start.longitude
            }
            if let initialName { name = initialName }
            if let preselectedLayerId {
                selectedLayerIds = [preselectedLayerId]
            } else if targetLayer == nil,
                      let smart = SmartDefaultLayer.placeLayer(in: allLayers.map(LayerLite.init),
                                                               lastUsedLayerId: UUID(uuidString: lastUsedLayerIdRaw)) {
                selectedLayerIds = [smart]
            }
        }
        recenterOnPin()
        initialSnapshot = currentSnapshot
    }

    private func setPin(_ coordinate: CLLocationCoordinate2D, recenter: Bool) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        if recenter { recenterOnPin() }
    }

    private func recenterOnPin() {
        guard let pin = pinCoordinate else { return }
        cameraPosition = .region(MKCoordinateRegion(
            center: pin,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }

    private func attemptCancel() {
        if hasUnsavedEdits {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard let pin = pinCoordinate, !trimmedName.isEmpty else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHours = hoursInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let place {
            place.name = trimmedName
            place.notes = trimmedNotes
            place.rating = rating
            place.hoursInfo = trimmedHours
            place.tags = parsedTags
            place.latitude = pin.latitude
            place.longitude = pin.longitude
            place.photoData = photoData
            if showsLayerChips {
                for layer in placeKindLayers {
                    if selectedLayerIds.contains(layer.id) {
                        place.addMembership(layer)
                    } else {
                        place.removeMembership(layer)
                    }
                }
            }
            place.updatedAt = Date()
            try? modelContext.save()
            confirm("Place updated", undo: nil)
        } else {
            let newPlace = Place(
                name: trimmedName,
                latitude: pin.latitude,
                longitude: pin.longitude,
                notes: trimmedNotes,
                rating: rating,
                hoursInfo: trimmedHours,
                tags: parsedTags
            )
            newPlace.photoData = photoData
            modelContext.insert(newPlace)

            let targets = targetLayer.map { [$0] } ?? placeKindLayers.filter { selectedLayerIds.contains($0.id) }
            for layer in targets { newPlace.addMembership(layer) }
            if let first = targets.first, first.kind == .places { lastUsedLayerIdRaw = first.id.uuidString }
            try? modelContext.save()

            let context = modelContext
            confirm(Self.savedMessage(layerNames: targets.map(\.name)),
                    undo: ToastAction(label: "Undo") {
                        context.delete(newPlace)
                        try? context.save()
                    })
        }
        dismiss()
    }

    /// Confirms and closes; no artificial delay. Without a toast host the
    /// form confirms with a haptic only.
    private func confirm(_ message: String, undo: ToastAction?) {
        if let toastCenter {
            // The toast host plays the success haptic when it presents.
            toastCenter.show(message, action: undo, duration: .seconds(undo == nil ? 2 : 4))
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// "Saved to Brunch", "Saved to Brunch + Favourites", "Saved to 3 layers".
    nonisolated static func savedMessage(layerNames: [String]) -> String {
        switch layerNames.count {
        case 0: return "Place saved"
        case 1, 2: return "Saved to " + layerNames.joined(separator: " + ")
        default: return "Saved to \(layerNames.count) layers"
        }
    }

    private struct Snapshot: Equatable {
        var name: String
        var notes: String
        var rating: Int
        var hoursInfo: String
        var tagsText: String
        var latitude: Double?
        var longitude: Double?
        var photoData: [Data]
        var selectedLayerIds: Set<UUID>
    }
}

// MARK: - Coordinate parsing

/// Liberal coordinate handling for the place form (Postel): accepts pasted pairs like
/// "53.3498, -6.2603", "53.3498 -6.2603", "(53.3498; -6.2603)", Unicode minus signs,
/// degree symbols, and N/S/E/W hemisphere suffixes. Pure logic, unit-tested.
enum CoordinateText {
    static func validated(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Parses a single signed decimal-degree component, e.g. "-6.26", "−6.26", "6.26° W".
    static func parseComponent(_ raw: String) -> Double? {
        var text = normalize(raw)
        var sign = 1.0
        if let last = text.last, "NSEW".contains(last) {
            if last == "S" || last == "W" { sign = -1 }
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, let value = Double(text) else { return nil }
        if sign < 0 && value < 0 { return nil } // "-6.26 W" is contradictory
        return value * sign
    }

    /// Parses "lat, lng" (comma, semicolon, or whitespace separated). Returns nil when
    /// the text isn't exactly two numbers or the pair is out of range.
    static func parse(_ raw: String) -> CLLocationCoordinate2D? {
        let text = normalize(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{} "))
        let separators = CharacterSet(charactersIn: ",;").union(.whitespaces)
        var parts = text.components(separatedBy: separators).filter { !$0.isEmpty }
        // Re-attach hemisphere letters separated by a space: ["53.3", "N", "6.2", "W"].
        var merged: [String] = []
        for part in parts {
            if part.count == 1, "NSEW".contains(part), let previous = merged.popLast() {
                merged.append(previous + part)
            } else {
                merged.append(part)
            }
        }
        parts = merged
        guard parts.count == 2,
              let lat = parseComponent(parts[0]),
              let lng = parseComponent(parts[1]) else { return nil }
        return validated(latitude: lat, longitude: lng)
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-") // minus sign
            .replacingOccurrences(of: "\u{2013}", with: "-") // en dash
            .replacingOccurrences(of: "°", with: "")
            .uppercased()
    }
}
