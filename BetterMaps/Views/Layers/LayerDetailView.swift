import SwiftUI
import SwiftData

struct LayerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Bindable var layer: Layer
    @State private var showEditForm = false
    @State private var showAddPlace = false
    /// Place currently open in the edit form (place layers only).
    @State private var editingPlace: Place?
    /// Trail editor presentation. `trail == nil` draws a new trail.
    @State private var editorTarget: EditorTarget?
    @State private var detailTrail: Trail?
    /// Set by the detail sheet's Edit button; the editor opens once the
    /// sheet has finished dismissing so the two presentations don't collide.
    @State private var pendingEditTrail: Trail?
    /// Fallback "Trail saved" confirmation when no screen-level ToastCenter
    /// is injected (the editor posts to that center when there is one).
    @State private var showSavedToast = false
    @State private var savedMessage = ""

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let trail: Trail?
    }

    var layerPlaces: [Place] {
        (layer.places ?? []).sorted { $0.name < $1.name }
    }

    var isWaypointPath: Bool { layer.kind == .waypointPath }

    private var trails: [Trail] {
        (layer.trails ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var pointsLabel: String {
        if isWaypointPath {
            let count = trails.count
            return "\(count) \(count == 1 ? "trail" : "trails") · \(layerPlaces.count) points"
        }
        return "\(layerPlaces.count) places"
    }

    private func pointCount(_ trail: Trail) -> Int {
        (layer.places ?? []).filter { $0.pathId == trail.pathId }.count
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: layer.symbolName)
                        .font(.title)
                        .foregroundStyle(Color(hex: layer.colorHex) ?? .red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(layer.name)
                            .font(.headline)
                        Text(pointsLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $layer.isVisible)
                        .labelsHidden()
                }
            }

            if isWaypointPath {
                if trails.isEmpty {
                    Section("Trails") {
                        Text("No trails yet. Tap New Trail, then tap the map to add points.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(trails) { trail in
                        trailSection(trail)
                    }
                }
            } else {
                Section("Places") {
                    if layerPlaces.isEmpty {
                        Text("No places in this layer yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(layerPlaces) { place in
                            Button(action: { editingPlace = place }) {
                                HStack {
                                    PlaceRowView(place: place)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: removePlaces)
                    }
                }
            }
        }
        .navigationTitle(layer.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Legacy waypoint layers predate `Trail`; create records so every
            // trail shows its name and length here.
            if isWaypointPath {
                TrailMigrator.ensureTrails(for: layer, in: modelContext)
                try? modelContext.save()
            }
        }
        .toolbar {
            // New Trail is the primary action for waypoint layers — one tap,
            // outside the menu (Fitts's Law).
            if isWaypointPath {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { editorTarget = EditorTarget(trail: nil) }) {
                        Label("New Trail", systemImage: "scribble.variable")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isWaypointPath {
                        Button(action: { showAddPlace = true }) {
                            Label("Add Place", systemImage: "plus")
                        }
                    }
                    Button(action: { showEditForm = true }) {
                        Label("Edit Layer", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditForm) {
            LayerFormView(layer: layer)
        }
        .sheet(isPresented: $showAddPlace) {
            AddPlaceToLayerView(layer: layer)
        }
        .sheet(item: $editingPlace) { place in
            PlaceFormView(place: place)
        }
        .sheet(item: $detailTrail, onDismiss: openPendingEdit) { trail in
            TrailDetailSheet(trail: trail) { pendingEditTrail = trail }
        }
        .fullScreenCover(item: $editorTarget) { target in
            TrailEditorView(layer: layer, trail: target.trail) { saved in
                editorTarget = nil
                if let saved, toastCenter == nil {
                    savedMessage = TrailFormat.savedMessage(for: saved)
                    showSavedToast = true
                }
            }
        }
        .toast(isPresented: $showSavedToast, message: savedMessage)
    }

    @ViewBuilder
    private func trailSection(_ trail: Trail) -> some View {
        Section {
            Button(action: { detailTrail = trail }) {
                HStack(spacing: 10) {
                    Image(systemName: trail.isSnapped
                          ? "point.topleft.down.to.point.bottomright.curvepath"
                          : "line.diagonal")
                        .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TrailFormat.summary(meters: trail.distanceMeters, points: pointCount(trail)))
                            .font(.body.monospacedDigit())
                        Text(trail.isSnapped ? "Follows paths" : "Straight lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows trail details")
        } header: {
            HStack {
                Text(trail.name.isEmpty ? "Untitled trail" : trail.name)
                    .textCase(nil)
                Spacer()
                Button {
                    TrailCommitter.setVisible(!trail.isVisible, for: trail, in: modelContext)
                } label: {
                    Image(systemName: trail.isVisible ? "eye" : "eye.slash")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(trail.isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(trail.isVisible ? "Hide \(trail.name) on map" : "Show \(trail.name) on map")
                .accessibilityAddTraits(trail.isVisible ? .isSelected : [])
                Button("Edit") { editorTarget = EditorTarget(trail: trail) }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Edit \(trail.name)")
            }
        }
    }

    private func openPendingEdit() {
        guard let trail = pendingEditTrail else { return }
        pendingEditTrail = nil
        editorTarget = EditorTarget(trail: trail)
    }

    /// Removes places from this layer; a place in no other layer is deleted.
    private func removePlaces(at offsets: IndexSet) {
        let sorted = layerPlaces
        for index in offsets {
            PlaceCleanup.detach(sorted[index], from: layer, in: modelContext)
        }
        try? modelContext.save()
    }
}

struct PlaceRowView: View {
    let place: Place

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.body)

                if place.rating > 0 {
                    RatingDisplayView(rating: place.rating)
                }

                if !place.tags.isEmpty {
                    Text(place.tags.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !place.notes.isEmpty {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
