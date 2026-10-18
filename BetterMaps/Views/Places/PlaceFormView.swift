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

    private var canSave: Bool { !trimmedName.isEmpty && pinCoordinate != nil }

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

                // Layer picker — only for new places without a pre-set target layer
                if !isEditing && targetLayer == nil && !allLayers.isEmpty {
                    Section("Add to Layer") {
                        ForEach(allLayers) { layer in
                            Button {
                                if selectedLayerIds.contains(layer.id) {
                                    selectedLayerIds.remove(layer.id)
                                } else {
                                    selectedLayerIds.insert(layer.id)
                                }
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(Color(hex: layer.colorHex) ?? .gray)
                                        .frame(width: 12, height: 12)
                                    Text(layer.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedLayerIds.contains(layer.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selectedLayerIds.contains(layer.id) ? .isSelected : [])
                        }
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
        } else {
            if let start = initialCoordinate ?? mapCenter {
                latitude = start.latitude
                longitude = start.longitude
            }
            if let initialName { name = initialName }
            if let preselectedLayerId { selectedLayerIds = [preselectedLayerId] }
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
            place.updatedAt = Date()
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

            if let targetLayer {
                if targetLayer.places == nil { targetLayer.places = [] }
                targetLayer.places?.append(newPlace)
            } else {
                // Add to user-selected layers (from the picker)
                for layer in allLayers where selectedLayerIds.contains(layer.id) {
                    if layer.places == nil { layer.places = [] }
                    layer.places?.append(newPlace)
                }
            }
        }

        // Confirm immediately and close; no artificial delay.
        if let toastCenter {
            // The toast host plays the success haptic when it presents.
            toastCenter.show(isEditing ? "Place updated" : "Place saved")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        dismiss()
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
