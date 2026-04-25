import SwiftUI
import SwiftData
import MapKit

/// Lightweight form for adding a single waypoint into a waypoint-path layer.
/// Kept for edit-one cases (e.g., entering exact coordinates). The primary
/// authoring experience is now `WaypointDrawView`, which handles rapid
/// tap-to-add for entire trails.
struct WaypointFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let layer: Layer

    @State private var name: String = ""
    @State private var latitude: Double = 53.3498
    @State private var longitude: Double = -6.2603
    @State private var isEndpoint: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Form {
                Section("Name (optional)") {
                    TextField("e.g. Trailhead", text: $name)
                }

                Section("Location") {
                    Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                        Marker(name.isEmpty ? "Waypoint" : name,
                               coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                    HStack {
                        Text("Lat").foregroundStyle(.secondary)
                        TextField("Latitude", value: $latitude, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Lng").foregroundStyle(.secondary)
                        TextField("Longitude", value: $longitude, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Toggle(isOn: $isEndpoint) {
                        Label("Start / End of path", systemImage: "flag.fill")
                    }
                } footer: {
                    Text("Endpoints connect to only their single nearest neighbor.")
                }
            }
            .navigationTitle("New Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                }
            }
            .onAppear {
                // Seed the camera at an existing waypoint in this layer if there is one.
                if let existing = layer.places?.first {
                    latitude = existing.latitude
                    longitude = existing.longitude
                }
                cameraPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let waypoint = Place(
            name: trimmed.isEmpty ? "Waypoint" : trimmed,
            latitude: latitude,
            longitude: longitude
        )
        waypoint.isWaypointEndpoint = isEndpoint
        modelContext.insert(waypoint)
        if layer.places == nil { layer.places = [] }
        layer.places?.append(waypoint)
        dismiss()
    }
}

// MARK: - Draw Mode

/// Full-screen rapid-authoring mode for waypoint-path layers.
///
/// Why a separate view (Selective Attention, Law of Common Region):
/// - The main map's tap = "search POI" or "dismiss search". In Draw Mode the
///   tap means "add waypoint at this coordinate". Different rules → different
///   screen, never ambiguous.
/// - The bottom toolbar and optional side panel only exist while the user is
///   authoring a path. The rest of the time they're invisible noise.
///
/// Why a staging array (Zeigarnik, transactional safety):
/// - Tap-to-add must feel instant (Doherty <400ms). If every tap wrote
///   straight to SwiftData / CloudKit, an accidental tap would be permanent
///   and risky. Drafts are mutated locally; Done commits, Cancel discards.
///
/// Why per-path grouping (Mental Model, Chunking):
/// - One layer can hold multiple disconnected trails. The graph algorithm
///   already runs MST per pathId via WaypointGraph.segmentsByPath; this view
///   just gives the user a way to start a new path or extend an existing one.
struct WaypointDrawView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let layer: Layer

    // fileprivate (not private) so WaypointEditSheet at file scope can refer
    // to these types directly. Still scoped to the file so they don't leak
    // into the rest of the project as a public API.
    typealias DraftPath = WaypointDrawDraftPath
    typealias DraftWaypoint = WaypointDrawDraftWaypoint

    /// Snapshot taken before each mutating action. Undo pops the last one.
    /// Capped to keep memory bounded — the user can hit Cancel for a full revert.
    private static let undoStackLimit = 50

    @State private var paths: [DraftPath] = []
    @State private var currentPathId: UUID?
    @State private var selectedWaypointId: UUID?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var undoStack: [[DraftPath]] = []
    @State private var showSidePanel: Bool = false
    @State private var showCancelConfirm: Bool = false
    /// Identity of the waypoint currently open in the precision-edit sheet.
    /// Set by long-pressing a row in the side panel; the sheet binds to the
    /// matching draft via this ID and mutates the staging array directly.
    @State private var editingWaypointId: UUID?

    private var totalWaypointCount: Int {
        paths.reduce(0) { $0 + $1.waypoints.count }
    }

    private var currentPath: DraftPath? {
        guard let id = currentPathId else { return nil }
        return paths.first(where: { $0.id == id })
    }

    private var hasUnsavedChanges: Bool { !undoStack.isEmpty }

    var body: some View {
        ZStack {
            mapCanvas
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                statusBanner
                Spacer()
                if showSidePanel {
                    // On iPhone the panel slides up from the bottom as a sheet-
                    // style overlay rather than a literal side bar. Same UX
                    // language as iOS Maps "Show Steps" — the user expects
                    // detail to come up, not flank the map.
                    waypointListPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomToolbar
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { hydrateFromLayer() }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Unsaved waypoint edits will be lost.")
        }
        .sheet(item: editingWaypointBinding) { editing in
            WaypointEditSheet(
                waypoint: editing,
                paths: paths,
                onSave: { updated, newPathId in
                    applyEdit(waypointId: editing.id, updated: updated, newPathId: newPathId)
                    editingWaypointId = nil
                },
                onCancel: { editingWaypointId = nil }
            )
        }
    }

    /// Bridges editingWaypointId (UUID?) to the sheet's `item:` binding which
    /// expects an Identifiable. Locating the actual draft by ID happens here
    /// so the sheet body sees the live current values, not a stale snapshot.
    private var editingWaypointBinding: Binding<DraftWaypoint?> {
        Binding(
            get: {
                guard let id = editingWaypointId else { return nil }
                return paths.flatMap(\.waypoints).first(where: { $0.id == id })
            },
            set: { newValue in
                editingWaypointId = newValue?.id
            }
        )
    }

    private func applyEdit(waypointId: UUID, updated: DraftWaypoint, newPathId: UUID?) {
        pushUndo()
        // If the user changed which path the waypoint belongs to, move it.
        // Otherwise mutate in place. Endpoint flags are NOT auto-recomputed
        // here — manual edit means the user is being explicit.
        let targetPathId = newPathId ?? findPathId(for: waypointId)
        for i in paths.indices {
            paths[i].waypoints.removeAll { $0.id == waypointId }
        }
        if let target = targetPathId,
           let idx = paths.firstIndex(where: { $0.id == target }) {
            paths[idx].waypoints.append(updated)
        }
        paths.removeAll { $0.waypoints.isEmpty }
        if let cur = currentPathId, !paths.contains(where: { $0.id == cur }) {
            currentPathId = paths.last?.id
        }
    }

    private func findPathId(for waypointId: UUID) -> UUID? {
        paths.first(where: { p in p.waypoints.contains(where: { $0.id == waypointId }) })?.id
    }

    // MARK: - Map canvas

    private var mapCanvas: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                ForEach(paths) { path in
                    // Live polyline per path. Uses the same MST graph as the
                    // main map renderer so what you see while drawing matches
                    // exactly what gets persisted.
                    let nodes = path.waypoints.map {
                        WaypointGraph.Node(
                            id: $0.id,
                            coordinate: $0.coordinate,
                            isEndpoint: $0.isEndpoint,
                            pathId: path.id
                        )
                    }
                    let segs = WaypointGraph.segments(for: nodes)
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(Color(hex: layer.colorHex) ?? .red,
                                    lineWidth: layer.lineWidth)
                    }

                    ForEach(path.waypoints) { wp in
                        Annotation("", coordinate: wp.coordinate, anchor: .center) {
                            waypointHandle(wp)
                                .onTapGesture { selectedWaypointId = wp.id }
                                .onLongPressGesture(minimumDuration: 0.4) {
                                    deleteWaypoint(wp.id)
                                }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .onTapGesture { screenPoint in
                // Single-finger tap on empty map = drop a new waypoint at the
                // tap coordinate. If a waypoint is currently selected, tapping
                // empty space deselects instead of adding (avoids accidental
                // adds while the user is scanning the popover).
                if selectedWaypointId != nil {
                    selectedWaypointId = nil
                    return
                }
                guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                addWaypoint(at: coord)
            }
        }
    }

    @ViewBuilder
    private func waypointHandle(_ wp: DraftWaypoint) -> some View {
        let isSelected = selectedWaypointId == wp.id
        let strokeColor = Color(hex: layer.colorHex) ?? .red
        ZStack {
            if isSelected {
                Circle()
                    .stroke(strokeColor, lineWidth: 3)
                    .frame(width: 28, height: 28)
            }
            Circle()
                .fill(wp.isEndpoint ? strokeColor : .white)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().stroke(strokeColor, lineWidth: 2)
                )
            if wp.isEndpoint {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Button(action: { confirmCancel() }) {
                Image(systemName: "chevron.left")
                    .font(.body.bold())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.headline)
                Text(currentPathStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Per-path counter (Goal-Gradient Effect: visible progress).
            Text("\(totalWaypointCount) wpts")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var currentPathStatusText: String {
        guard let path = currentPath else { return "Tap to start drawing" }
        return "Drawing: \(path.name) • \(path.waypoints.count) waypoints"
    }

    // MARK: - Side panel (waypoint list, grouped by path)

    private var waypointListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Waypoints")
                    .font(.headline)
                Spacer()
                Button(action: { withAnimation { showSidePanel = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(paths) { path in
                        pathSection(path)
                    }
                    Button(action: { startNewPath() }) {
                        Label("Start New Trail", systemImage: "plus.circle")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func pathSection(_ path: DraftPath) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Editable inline path name. Section header doubles as the
                // rename affordance — no extra tap target needed.
                TextField("Path name", text: bindingForPathName(path.id))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(path.waypoints.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if path.id == currentPathId {
                    Image(systemName: "pencil.tip")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture { currentPathId = path.id }

            ForEach(path.waypoints) { wp in
                waypointRow(wp, in: path)
            }
            Divider()
        }
    }

    @ViewBuilder
    private func waypointRow(_ wp: DraftWaypoint, in path: DraftPath) -> some View {
        let isSelected = selectedWaypointId == wp.id
        HStack(spacing: 10) {
            Image(systemName: wp.isEndpoint ? "flag.fill" : "circle.fill")
                .font(.caption)
                .foregroundStyle(wp.isEndpoint ? .orange : Color(hex: layer.colorHex) ?? .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(wp.name.isEmpty ? "Waypoint" : wp.name)
                    .font(.subheadline)
                Text(String(format: "%.5f, %.5f", wp.latitude, wp.longitude))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: { toggleEndpoint(wp.id) }) {
                Image(systemName: wp.isEndpoint ? "flag.fill" : "flag")
                    .font(.caption)
                    .foregroundStyle(wp.isEndpoint ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            Button(action: { deleteWaypoint(wp.id) }) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.1) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedWaypointId = wp.id
            // Pan camera to the tapped waypoint (Goal-Gradient: physical move
            // confirms which row maps to which point).
            cameraPosition = .region(MKCoordinateRegion(
                center: wp.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            // Long-press = open precision edit sheet (name, exact lat/lng,
            // endpoint flag, path reassignment). Tap stays as the cheap
            // select+pan action so the rapid review flow isn't slowed down.
            editingWaypointId = wp.id
        }
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            toolbarButton("xmark", label: "Cancel") { confirmCancel() }
            toolbarButton("arrow.uturn.backward", label: "Undo", disabled: undoStack.isEmpty) { undo() }
            toolbarButton("list.bullet", label: "List", highlighted: showSidePanel) {
                withAnimation { showSidePanel.toggle() }
            }
            toolbarButton("plus.circle", label: "New") { startNewPath() }
            toolbarButton("checkmark", label: "Done", primary: true) { commit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func toolbarButton(
        _ systemName: String,
        label: String,
        primary: Bool = false,
        highlighted: Bool = false,
        disabled: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                primary ? AnyShapeStyle(Color.blue.opacity(0.15)) :
                highlighted ? AnyShapeStyle(Color.blue.opacity(0.1)) :
                AnyShapeStyle(Color.clear)
            )
            .foregroundStyle(primary ? .blue : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    // MARK: - Mutations (all gated through pushUndo so undo always works)

    private func pushUndo() {
        undoStack.append(paths)
        if undoStack.count > Self.undoStackLimit {
            undoStack.removeFirst(undoStack.count - Self.undoStackLimit)
        }
    }

    private func addWaypoint(at coord: CLLocationCoordinate2D) {
        pushUndo()
        // If no current path, start a fresh one. Defaults the user into a
        // sensible state on first tap — no need to hit "New Path" first.
        if currentPathId == nil {
            startNewPathInternal()
        }
        guard let pathId = currentPathId,
              let pathIndex = paths.firstIndex(where: { $0.id == pathId }) else { return }

        // Auto-flag rule, per path: first waypoint = start, last waypoint = end.
        // Adding a new last point demotes the previous last from end → middle.
        if !paths[pathIndex].waypoints.isEmpty {
            let lastIndex = paths[pathIndex].waypoints.count - 1
            // Only un-flag if it was the auto-set end (i.e., user didn't
            // manually flag a middle point as endpoint). We can't fully
            // distinguish so this is conservative: only demote if there are
            // already 2+ waypoints and the last is currently flagged.
            if paths[pathIndex].waypoints.count >= 2,
               paths[pathIndex].waypoints[lastIndex].isEndpoint,
               // Check it isn't ALSO the start (1-waypoint paths have last=start)
               lastIndex != 0 {
                paths[pathIndex].waypoints[lastIndex].isEndpoint = false
            }
        }

        let isFirst = paths[pathIndex].waypoints.isEmpty
        let new = DraftWaypoint(
            id: UUID(),
            latitude: coord.latitude,
            longitude: coord.longitude,
            name: "",
            isEndpoint: true,                  // last added = endpoint (auto)
            existingPlaceId: nil
        )
        // First waypoint of a path: it IS the start AND end of a 1-point path,
        // and we want the next add to demote it correctly. Setting isEndpoint
        // = true on the first point gives the visual flag immediately.
        _ = isFirst
        paths[pathIndex].waypoints.append(new)
        selectedWaypointId = new.id
    }

    private func deleteWaypoint(_ id: UUID) {
        pushUndo()
        for i in paths.indices {
            paths[i].waypoints.removeAll { $0.id == id }
        }
        // Re-flag endpoints if removal made the path's first/last shift.
        for i in paths.indices {
            for j in paths[i].waypoints.indices {
                paths[i].waypoints[j].isEndpoint =
                    (j == 0 || j == paths[i].waypoints.count - 1)
            }
        }
        // Drop empty paths so they don't pile up in the side panel.
        paths.removeAll { $0.waypoints.isEmpty }
        if let cur = currentPathId, !paths.contains(where: { $0.id == cur }) {
            currentPathId = paths.last?.id
        }
        if selectedWaypointId == id { selectedWaypointId = nil }
    }

    private func toggleEndpoint(_ id: UUID) {
        pushUndo()
        for i in paths.indices {
            for j in paths[i].waypoints.indices where paths[i].waypoints[j].id == id {
                paths[i].waypoints[j].isEndpoint.toggle()
            }
        }
    }

    private func startNewPath() {
        pushUndo()
        startNewPathInternal()
    }

    private func startNewPathInternal() {
        let nextNumber = paths.count + 1
        let newPath = DraftPath(
            id: UUID(),
            name: "Trail \(nextNumber)",
            waypoints: []
        )
        paths.append(newPath)
        currentPathId = newPath.id
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        paths = prev
        // Selected waypoint may no longer exist after undo.
        if let sel = selectedWaypointId,
           !paths.flatMap(\.waypoints).contains(where: { $0.id == sel }) {
            selectedWaypointId = nil
        }
    }

    private func confirmCancel() {
        if hasUnsavedChanges {
            showCancelConfirm = true
        } else {
            dismiss()
        }
    }

    // MARK: - Hydrate / commit

    private func hydrateFromLayer() {
        let existingPlaces = layer.places ?? []
        let existingPathNames = layer.pathNames

        // Group existing places by pathId. nil pathIds get bucketed into a
        // single "Trail 1" so legacy waypoints (pre-multi-path) keep their
        // line and can be split later.
        var grouped: [UUID?: [Place]] = [:]
        for place in existingPlaces { grouped[place.pathId, default: []].append(place) }

        var seedPaths: [DraftPath] = []

        // Named paths first, in stable order.
        for (uuid, name) in existingPathNames.sorted(by: { $0.value < $1.value }) {
            let places = grouped[uuid] ?? []
            seedPaths.append(DraftPath(
                id: uuid,
                name: name,
                waypoints: places.enumerated().map { idx, place in
                    DraftWaypoint(
                        id: place.id,
                        latitude: place.latitude,
                        longitude: place.longitude,
                        name: place.name,
                        isEndpoint: place.isWaypointEndpoint,
                        existingPlaceId: place.id
                    )
                }
            ))
            grouped[uuid] = nil
        }

        // Any remaining grouped buckets that weren't in pathNames (shouldn't
        // happen but defends against partial migrations / sync hiccups).
        for (uuid, places) in grouped where uuid != nil && !places.isEmpty {
            let id = uuid!
            seedPaths.append(DraftPath(
                id: id,
                name: "Trail \(seedPaths.count + 1)",
                waypoints: places.map {
                    DraftWaypoint(
                        id: $0.id,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        name: $0.name,
                        isEndpoint: $0.isWaypointEndpoint,
                        existingPlaceId: $0.id
                    )
                }
            ))
        }

        // Legacy nil-pathId waypoints → one bucket.
        if let nilGroup = grouped[nil], !nilGroup.isEmpty {
            seedPaths.append(DraftPath(
                id: UUID(),
                name: "Trail \(seedPaths.count + 1)",
                waypoints: nilGroup.map {
                    DraftWaypoint(
                        id: $0.id,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        name: $0.name,
                        isEndpoint: $0.isWaypointEndpoint,
                        existingPlaceId: $0.id
                    )
                }
            ))
        }

        paths = seedPaths
        currentPathId = paths.last?.id

        // Center camera on the data we have, or fall back to Dublin.
        let allCoords = paths.flatMap { $0.waypoints.map(\.coordinate) }
        if let region = boundingRegion(for: allCoords) {
            cameraPosition = .region(region)
        } else {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }

    /// Persist drafts to SwiftData and dismiss.
    /// Strategy: rebuild the layer's places list from drafts, deleting any
    /// existing Places that were removed during the session and inserting new
    /// ones. Existing Places that survived are mutated in place so their IDs
    /// stay stable (for any external references like favorites).
    private func commit() {
        let existingPlaces = layer.places ?? []
        let existingById: [UUID: Place] = Dictionary(uniqueKeysWithValues: existingPlaces.map { ($0.id, $0) })
        let draftIds = Set(paths.flatMap { $0.waypoints.compactMap(\.existingPlaceId) })

        // Delete existing places no longer in any draft path.
        for place in existingPlaces where !draftIds.contains(place.id) {
            layer.places?.removeAll { $0.id == place.id }
            // Only delete the Place model if it has no other layer membership.
            // Same rule as LayerDetailView.removePlaces — waypoint-path Places
            // typically only belong to one layer, but defend anyway.
            if (place.layers?.isEmpty ?? true) {
                modelContext.delete(place)
            }
        }

        // Upsert drafts.
        for path in paths {
            for draft in path.waypoints {
                if let existingId = draft.existingPlaceId,
                   let place = existingById[existingId] {
                    place.latitude = draft.latitude
                    place.longitude = draft.longitude
                    place.name = draft.name.isEmpty ? "Waypoint" : draft.name
                    place.isWaypointEndpoint = draft.isEndpoint
                    place.pathId = path.id
                } else {
                    let new = Place(
                        name: draft.name.isEmpty ? "Waypoint" : draft.name,
                        latitude: draft.latitude,
                        longitude: draft.longitude
                    )
                    new.isWaypointEndpoint = draft.isEndpoint
                    new.pathId = path.id
                    modelContext.insert(new)
                    if layer.places == nil { layer.places = [] }
                    layer.places?.append(new)
                }
            }
        }

        // Persist path names. Empty / orphaned ids drop out.
        var names: [UUID: String] = [:]
        for path in paths where !path.waypoints.isEmpty {
            names[path.id] = path.name
        }
        layer.pathNames = names

        dismiss()
    }

    // MARK: - Helpers

    private func bindingForPathName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { paths.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                guard let i = paths.firstIndex(where: { $0.id == id }) else { return }
                pushUndo()
                paths[i].name = newValue
            }
        )
    }

    private func boundingRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Draft types (file scope so WaypointEditSheet can reference them)

struct WaypointDrawDraftPath: Identifiable {
    let id: UUID
    var name: String
    var waypoints: [WaypointDrawDraftWaypoint]
}

struct WaypointDrawDraftWaypoint: Identifiable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    var name: String
    var isEndpoint: Bool
    /// nil = newly created during this draw session; non-nil = a Place
    /// that already exists in SwiftData and may need an update on commit.
    var existingPlaceId: UUID?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Edit sheet

/// Precision-edit sheet for a single waypoint, shown when the user long-
/// presses a row in WaypointDrawView's side panel. Lets the user fix the
/// name, type exact lat/lng, toggle the endpoint flag, and reassign the
/// waypoint to a different path within the same layer.
///
/// Saves go back through WaypointDrawView.applyEdit (which calls pushUndo)
/// so transactional Cancel still works — nothing here writes to SwiftData
/// directly.
private struct WaypointEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let waypoint: WaypointDrawDraftWaypoint
    let paths: [WaypointDrawDraftPath]
    let onSave: (WaypointDrawDraftWaypoint, UUID?) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var isEndpoint: Bool = false
    @State private var selectedPathId: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Trailhead", text: $name)
                }

                Section("Location") {
                    HStack {
                        Text("Lat").foregroundStyle(.secondary)
                        TextField("Latitude", value: $latitude, format: .number.precision(.fractionLength(0...7)))
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text("Lng").foregroundStyle(.secondary)
                        TextField("Longitude", value: $longitude, format: .number.precision(.fractionLength(0...7)))
                            .keyboardType(.numbersAndPunctuation)
                    }
                }

                Section {
                    Toggle(isOn: $isEndpoint) {
                        Label("Start / End of path", systemImage: "flag.fill")
                    }
                } footer: {
                    Text("Endpoints connect to only their single nearest neighbor.")
                }

                if paths.count > 1 {
                    Section("Path") {
                        Picker("Move to", selection: $selectedPathId) {
                            ForEach(paths) { path in
                                Text(path.name).tag(Optional(path.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                name = waypoint.name
                latitude = waypoint.latitude
                longitude = waypoint.longitude
                isEndpoint = waypoint.isEndpoint
                selectedPathId = paths.first(where: { p in
                    p.waypoints.contains(where: { $0.id == waypoint.id })
                })?.id
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let updated = WaypointDrawDraftWaypoint(
            id: waypoint.id,
            latitude: latitude,
            longitude: longitude,
            name: name.trimmingCharacters(in: .whitespaces),
            isEndpoint: isEndpoint,
            existingPlaceId: waypoint.existingPlaceId
        )
        onSave(updated, selectedPathId)
        dismiss()
    }
}
