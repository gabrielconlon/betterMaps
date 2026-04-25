import SwiftUI
import SwiftData

struct LayerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var layer: Layer
    @State private var showEditForm = false
    @State private var showAddPlace = false
    @State private var showAddWaypoint = false
    @State private var showDrawMode = false
    /// Per-pathId expansion state for the trail-grouped waypoint list.
    /// Default state (set on first appear): all trails expanded.
    @State private var expandedPathIds: Set<UUID> = []
    @State private var didSeedExpansion: Bool = false
    /// Place currently open in the edit form. Tapping a row in the list
    /// (place layers) sets this to push the precision-edit form. The user
    /// reported tap-to-edit was missing — every row was non-interactive.
    @State private var editingPlace: Place?

    var layerPlaces: [Place] {
        (layer.places ?? []).sorted { $0.name < $1.name }
    }

    var isWaypointPath: Bool { layer.kind == .waypointPath }

    var pointsLabel: String {
        let count = layerPlaces.count
        return isWaypointPath ? "\(count) waypoints" : "\(count) places"
    }

    /// Sort function shared by all trail groupings: tap-order first, then
    /// creation date as a tiebreaker for legacy waypoints (sortIndex == 0).
    private func sortByTapOrder(_ places: [Place]) -> [Place] {
        places.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Groups the layer's waypoints by pathId for the trail-grouped section
    /// rendering. Returns ordered (id, name, places) tuples — id is nil for
    /// the legacy "Ungrouped" bucket of waypoints predating multi-path
    /// support. Stable order: named trails alphabetically, then a single
    /// "Ungrouped" bucket if any nil-pathId waypoints exist.
    private var trailGroups: [(id: UUID?, name: String, places: [Place])] {
        let all = layer.places ?? []
        var byPathId: [UUID?: [Place]] = [:]
        for place in all { byPathId[place.pathId, default: []].append(place) }

        var result: [(UUID?, String, [Place])] = []
        let pathNames = layer.pathNames

        // Named trails sorted alphabetically. Trails that have a UUID but no
        // name in pathNames get a fallback "Trail (unnamed)" so they're still
        // visible (defensive — shouldn't normally happen).
        let knownIds: [UUID] = byPathId.keys.compactMap { $0 }
        let sortedKnown = knownIds.sorted { (a, b) in
            let na = pathNames[a] ?? "Trail (unnamed)"
            let nb = pathNames[b] ?? "Trail (unnamed)"
            return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending
        }
        for id in sortedKnown {
            result.append((
                id,
                pathNames[id] ?? "Trail (unnamed)",
                sortByTapOrder(byPathId[id] ?? [])
            ))
        }

        // Legacy bucket — only show if non-empty.
        if let nilPlaces = byPathId[nil], !nilPlaces.isEmpty {
            result.append((nil, "Ungrouped", sortByTapOrder(nilPlaces)))
        }

        return result
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
                Section {
                    Text("Trails draw their lines in tap-order. Use Draw Path to add or rearrange waypoints; the flag icon marks the start and end.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isWaypointPath {
                if layerPlaces.isEmpty {
                    Section("Waypoints") {
                        Text("No waypoints yet. Tap Draw Path to start a trail.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // One section per trail. Each section is collapsible
                    // independently — long lists never wall off the others.
                    ForEach(trailGroups, id: \.id) { group in
                        trailSection(group)
                    }
                }
            } else {
                Section("Places") {
                    if layerPlaces.isEmpty {
                        Text("No places in this layer yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(layerPlaces) { place in
                            // Tap a place row to open its edit form. The user
                            // reported this regressed — rows used to be
                            // tappable for edit, but the recent rebuilds
                            // turned them into static cells. Use Button +
                            // .plain style so the cell still looks like a
                            // List row but actually responds.
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
            // Seed expansion state once, defaulting to all trails expanded.
            // Subsequent views preserve the user's manual collapse choices.
            if !didSeedExpansion {
                expandedPathIds = Set(trailGroups.compactMap(\.id))
                didSeedExpansion = true
            }
        }
        .toolbar {
            // Draw Path is the primary action for waypoint layers — surface it
            // outside the menu so it's one tap (Fitts's Law). The "Add Waypoint"
            // form remains available in the menu as the precision-entry escape
            // hatch.
            if isWaypointPath {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showDrawMode = true }) {
                        Label("Draw Path", systemImage: "scribble.variable")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isWaypointPath {
                        Button(action: { showAddWaypoint = true }) {
                            Label("Add Waypoint (Form)", systemImage: "plus")
                        }
                    } else {
                        Button(action: { showAddPlace = true }) {
                            Label("Add Place", systemImage: "plus")
                        }
                    }
                    Button(action: { showEditForm = true }) {
                        Label("Edit Layer", systemImage: "pencil")
                    }
                    Button(action: { layer.isFavorite.toggle() }) {
                        Label(
                            layer.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: layer.isFavorite ? "star.slash" : "star.fill"
                        )
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
        .sheet(isPresented: $showAddWaypoint) {
            WaypointFormView(layer: layer)
        }
        .sheet(item: $editingPlace) { place in
            PlaceFormView(place: place)
        }
        .fullScreenCover(isPresented: $showDrawMode) {
            // Full-screen cover — Draw Mode owns the entire screen so the
            // user can rapid-tap without other UI competing for hits.
            NavigationStack {
                WaypointDrawView(layer: layer)
            }
        }
    }

    @ViewBuilder
    private func trailSection(_ group: (id: UUID?, name: String, places: [Place])) -> some View {
        let isExpanded = group.id.map { expandedPathIds.contains($0) } ?? true
        Section {
            if isExpanded {
                ForEach(group.places) { place in
                    Button(action: { editingPlace = place }) {
                        HStack {
                            WaypointRowView(place: place)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in removeFromTrail(group: group, at: offsets) }
                .onMove { source, destination in
                    moveInTrail(group: group, from: source, to: destination)
                }
            }
        } header: {
            // Tappable section header to toggle expansion. Only shown for
            // waypoint-path layers; the chevron mirrors the side-panel UX
            // in WaypointDrawView for visual consistency.
            HStack(spacing: 8) {
                if let id = group.id {
                    Button(action: { toggleExpand(id) }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Legacy "Ungrouped" bucket — non-collapsible since it
                    // doesn't have a stable id we can use.
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(group.name)
                    .textCase(nil)
                Spacer()
                Text("\(group.places.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textCase(nil)
            }
        }
    }

    private func toggleExpand(_ id: UUID) {
        if expandedPathIds.contains(id) {
            expandedPathIds.remove(id)
        } else {
            expandedPathIds.insert(id)
        }
    }

    /// Reorder places within a trail. Writes incremental sortIndex values to
    /// the underlying Place rows so the ordering persists across launches and
    /// CloudKit syncs. The endpoint flag stays as the user set it — drag
    /// only affects order, not flag state.
    private func moveInTrail(group: (id: UUID?, name: String, places: [Place]), from source: IndexSet, to destination: Int) {
        var reordered = group.places
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, place) in reordered.enumerated() {
            place.sortIndex = index
        }
    }

    private func removeFromTrail(group: (id: UUID?, name: String, places: [Place]), at offsets: IndexSet) {
        for index in offsets {
            guard index < group.places.count else { continue }
            let place = group.places[index]
            layer.places?.removeAll { $0.id == place.id }
            if isWaypointPath, (place.layers?.isEmpty ?? true) {
                modelContext.delete(place)
            }
        }
    }

    private func removePlaces(at offsets: IndexSet) {
        let sorted = layerPlaces
        for index in offsets {
            let place = sorted[index]
            layer.places?.removeAll { $0.id == place.id }
            // For waypoint-path layers, points exist only inside the layer — also delete the Place.
            if isWaypointPath, (place.layers?.isEmpty ?? true) {
                modelContext.delete(place)
            }
        }
    }
}

struct WaypointRowView: View {
    @Bindable var place: Place

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name.isEmpty ? "Waypoint" : place.name)
                    .font(.body)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $place.isWaypointEndpoint) {
                Label("Start/End", systemImage: place.isWaypointEndpoint ? "flag.fill" : "flag")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .tint(.orange)
        }
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
