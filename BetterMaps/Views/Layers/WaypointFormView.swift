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
    /// Trail IDs whose waypoint rows are visible in the side panel. By
    /// default only the active trail expands so many-trail layers don't
    /// push the panel toward its height cap. Tapping a chevron toggles
    /// the path's membership here.
    @State private var expandedPathIds: Set<UUID> = []
    /// Trail being renamed via the explicit rename alert. Separate from
    /// currentPathId because renaming and selecting are different actions
    /// (the previous "TextField is the section header" design conflated
    /// them — every tap to select also opened the keyboard).
    @State private var renamingPathId: UUID?
    @State private var renamingText: String = ""
    /// Snapshot taken at the start of a drag-to-move on a waypoint handle.
    /// Pushed onto the undo stack at .onEnded so the entire drag is one
    /// undo step instead of one-per-frame. nil when no drag is in flight.
    @State private var draggingWaypointSnapshot: [DraftPath]?
    @State private var draggingWaypointId: UUID?

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
        .alert("Rename Trail",
               isPresented: Binding(
                get: { renamingPathId != nil },
                set: { if !$0 { renamingPathId = nil } }
               )) {
            TextField("Trail name", text: $renamingText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingPathId = nil }
        } message: {
            Text("Give this trail a name you'll recognize on the map.")
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
                    // Live polyline per path — ordered traversal: connect the
                    // waypoints in the order the user tapped them. path.waypoints
                    // is already in tap-order by construction (we append on add).
                    let nodes = path.waypoints.map {
                        WaypointGraph.Node(
                            id: $0.id,
                            coordinate: $0.coordinate,
                            isEndpoint: $0.isEndpoint,
                            pathId: path.id
                        )
                    }
                    let segs = WaypointGraph.orderedSegments(for: nodes)
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
                                // Drag gesture on the annotation handle.
                                // minimumDistance:8 stops a stationary press
                                // from registering as a drag (which would
                                // race the long-press / tap). Once a drag
                                // starts, every onChanged frame converts the
                                // current finger location to a map coord via
                                // proxy.convert and rewrites the waypoint's
                                // lat/lon — the Annotation's coordinate
                                // binding rerenders so the handle and any
                                // polyline through it move under the finger.
                                .gesture(
                                    DragGesture(minimumDistance: 8, coordinateSpace: .local)
                                        .onChanged { value in
                                            // Snapshot once at drag start so
                                            // the entire drag is one undo
                                            // entry, not one per frame.
                                            if draggingWaypointSnapshot == nil {
                                                draggingWaypointSnapshot = paths
                                                draggingWaypointId = wp.id
                                                selectedWaypointId = wp.id
                                            }
                                            if let coord = proxy.convert(value.location, from: .local) {
                                                updateWaypointCoord(wp.id, to: coord)
                                            }
                                        }
                                        .onEnded { _ in
                                            if let snapshot = draggingWaypointSnapshot {
                                                undoStack.append(snapshot)
                                                if undoStack.count > Self.undoStackLimit {
                                                    undoStack.removeFirst(undoStack.count - Self.undoStackLimit)
                                                }
                                            }
                                            draggingWaypointSnapshot = nil
                                            draggingWaypointId = nil
                                        }
                                )
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .onTapGesture {
                // Single-finger tap on empty map = deselect any current
                // waypoint. NOT an add. Single-tap-to-add was too sensitive
                // — accidental drops happened while panning, scanning the
                // map, or aiming for a handle. Add is now long-press (below)
                // so the user has to commit to the gesture deliberately.
                selectedWaypointId = nil
            }
            .gesture(
                // Long-press to drop a waypoint at the press location. The
                // sequenced(before: DragGesture(0)) trick lets us capture
                // the release coordinate — SwiftUI's plain
                // .onLongPressGesture has no location parameter. Same
                // pattern the main map uses for "drop a pin".
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value,
                              let coord = proxy.convert(drag.location, from: .local)
                        else { return }
                        addWaypoint(at: coord)
                    }
            )
        }
    }

    @ViewBuilder
    private func waypointHandle(_ wp: DraftWaypoint) -> some View {
        let isSelected = selectedWaypointId == wp.id
        let isDragging = draggingWaypointId == wp.id
        let strokeColor = Color(hex: layer.colorHex) ?? .red
        ZStack {
            if isSelected || isDragging {
                Circle()
                    .stroke(strokeColor, lineWidth: 3)
                    .frame(width: isDragging ? 36 : 28, height: isDragging ? 36 : 28)
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
        .scaleEffect(isDragging ? 1.15 : 1.0)
        .shadow(color: isDragging ? strokeColor.opacity(0.6) : .clear, radius: 6)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
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
        guard let path = currentPath else { return "Long-press the map to start drawing" }
        return "Drawing: \(path.name) • \(path.waypoints.count) wpts • long-press to add"
    }

    // MARK: - Side panel (waypoint list, grouped by path)

    private var waypointListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Waypoints")
                    .font(.headline)
                Spacer()
                // EditButton enables drag handles + delete circles on the
                // List rows below. Out of edit mode the rows show normally.
                EditButton()
                    .font(.subheadline)
                Button(action: { withAnimation { showSidePanel = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            List {
                ForEach(paths) { path in
                    pathSection(path)
                }
                Section {
                    Button(action: { startNewPath() }) {
                        Label("Start New Trail", systemImage: "plus.circle")
                            .font(.subheadline.weight(.medium))
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: 360)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func pathSection(_ path: DraftPath) -> some View {
        let isActive = path.id == currentPathId
        let isExpanded = expandedPathIds.contains(path.id)

        Section {
            if isExpanded {
                ForEach(path.waypoints) { wp in
                    waypointRow(wp, in: path)
                }
                .onMove { source, destination in
                    reorder(in: path.id, from: source, to: destination)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Button(action: { toggleExpand(path.id) }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text(path.name)
                    .font(.subheadline.weight(isActive ? .bold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .textCase(nil)

                if isActive {
                    Image(systemName: "pencil.tip")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                Spacer()

                Text("\(path.waypoints.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textCase(nil)

                Button(action: { startRename(path) }) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isActive ? Color.blue.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { selectPath(path.id) }
        }
    }

    private func toggleExpand(_ id: UUID) {
        if expandedPathIds.contains(id) {
            expandedPathIds.remove(id)
        } else {
            expandedPathIds.insert(id)
        }
    }

    private func selectPath(_ id: UUID) {
        currentPathId = id
        // Auto-expand so the user can immediately verify which waypoints
        // are in the trail they just selected.
        expandedPathIds.insert(id)
    }

    private func startRename(_ path: DraftPath) {
        renamingPathId = path.id
        renamingText = path.name
    }

    private func commitRename() {
        guard let id = renamingPathId,
              let i = paths.firstIndex(where: { $0.id == id }) else {
            renamingPathId = nil
            return
        }
        let trimmed = renamingText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != paths[i].name {
            pushUndo()
            paths[i].name = trimmed
        }
        renamingPathId = nil
    }

    @ViewBuilder
    private func waypointRow(_ wp: DraftWaypoint, in path: DraftPath) -> some View {
        let isSelected = selectedWaypointId == wp.id
        // Flag is now a manual user annotation (the toggle on the right).
        // "start" / "end" semantics come from BOTH the flag AND position:
        //   flagged + first row → start
        //   flagged + last row → end
        //   flagged + middle → just visually flagged (no label)
        //   unflagged → no flag, no label
        // This matches the user's mental model: drag controls position, flag
        // controls "this is an endpoint" — the combination derives the label.
        let position = path.waypoints.firstIndex(where: { $0.id == wp.id }) ?? 0
        let isFirst = position == 0
        let isLast = position == path.waypoints.count - 1
        let positionLabel: String? = {
            guard wp.isEndpoint else { return nil }
            if isFirst && isLast { return "start / end" }
            if isFirst { return "start" }
            if isLast { return "end" }
            return nil
        }()
        let dotColor = wp.isEndpoint ? .orange : (Color(hex: layer.colorHex) ?? .secondary)

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 14, height: 14)
                if wp.isEndpoint {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(wp.name.isEmpty ? "Waypoint" : wp.name)
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Text(String(format: "%.5f, %.5f", wp.latitude, wp.longitude))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if let label = positionLabel {
                        Text("• \(label)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()

            // Manual flag toggle. Independent of position — user controls
            // whether a waypoint is "an endpoint". Combined with drag-to-
            // reorder, this restores the model the user asked for:
            // "flagged + at top → start; flagged + at bottom → end".
            Button(action: { toggleEndpoint(wp.id) }) {
                Image(systemName: wp.isEndpoint ? "flag.fill" : "flag")
                    .font(.caption)
                    .foregroundStyle(wp.isEndpoint ? .orange : .secondary)
            }
            .buttonStyle(.plain)

            // Always-visible edit affordance. Long-press also opens the
            // edit sheet, but in Edit mode (drag handles active) the
            // long-press gesture conflicts with reorder, so this button
            // is the reliable way to edit a waypoint's name / coords from
            // the list.
            Button(action: { editingWaypointId = wp.id }) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .listRowSeparator(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedWaypointId = wp.id
            cameraPosition = .region(MKCoordinateRegion(
                center: wp.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            editingWaypointId = wp.id
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteWaypoint(wp.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
        if currentPathId == nil {
            startNewPathInternal()
        }
        guard let pathId = currentPathId,
              let pathIndex = paths.firstIndex(where: { $0.id == pathId }) else { return }

        let new = DraftWaypoint(
            id: UUID(),
            latitude: coord.latitude,
            longitude: coord.longitude,
            name: "",
            isEndpoint: paths[pathIndex].waypoints.isEmpty,   // first auto-flags
            existingPlaceId: nil
        )

        // Insert-between: if the long-press landed near a segment of the
        // current path, drop the new waypoint at that segment's index so the
        // line still passes through it in order. This lets the user refine
        // the path mid-line without manually reordering afterwards.
        if let insertAt = nearestSegmentInsertionIndex(
            for: coord,
            in: paths[pathIndex].waypoints,
            thresholdMeters: 30
        ) {
            paths[pathIndex].waypoints.insert(new, at: insertAt)
        } else {
            paths[pathIndex].waypoints.append(new)
        }
        selectedWaypointId = new.id
    }

    private func deleteWaypoint(_ id: UUID) {
        pushUndo()
        for i in paths.indices {
            paths[i].waypoints.removeAll { $0.id == id }
        }
        paths.removeAll { $0.waypoints.isEmpty }
        if let cur = currentPathId, !paths.contains(where: { $0.id == cur }) {
            currentPathId = paths.last?.id
        }
        if selectedWaypointId == id { selectedWaypointId = nil }
    }

    /// Live waypoint reposition during a drag-to-move gesture. Called
    /// many times per second from DragGesture.onChanged — does NOT push
    /// undo here; the gesture's onEnded pushes a single snapshot taken
    /// at drag start so an entire drag is one Undo step.
    private func updateWaypointCoord(_ id: UUID, to coord: CLLocationCoordinate2D) {
        for i in paths.indices {
            for j in paths[i].waypoints.indices where paths[i].waypoints[j].id == id {
                paths[i].waypoints[j].latitude = coord.latitude
                paths[i].waypoints[j].longitude = coord.longitude
            }
        }
    }

    /// Manually toggle the endpoint flag on a waypoint. The flag is now
    /// independent of position — it's a user annotation. Whether a flag
    /// reads as "start" or "end" is derived in the UI from the row's
    /// position in its path: flagged + first row → start, flagged + last
    /// row → end, flagged + middle → just visually flagged.
    private func toggleEndpoint(_ id: UUID) {
        pushUndo()
        for i in paths.indices {
            for j in paths[i].waypoints.indices where paths[i].waypoints[j].id == id {
                paths[i].waypoints[j].isEndpoint.toggle()
            }
        }
    }

    /// Reorder hook used by SwiftUI List's .onMove. Operates on a single
    /// path's waypoints (drag handles only show within a section).
    private func reorder(in pathId: UUID, from source: IndexSet, to destination: Int) {
        guard let i = paths.firstIndex(where: { $0.id == pathId }) else { return }
        pushUndo()
        paths[i].waypoints.move(fromOffsets: source, toOffset: destination)
    }

    /// If `coord` is within `thresholdMeters` of any segment connecting two
    /// consecutive waypoints in `path`, returns the index where a new point
    /// should be inserted to land on that segment. Otherwise returns nil so
    /// the caller can append to the end instead.
    ///
    /// Distance computation uses a flat-earth projection — fine at the
    /// 30-meter scale we're checking; the curvature error over 30m is well
    /// under a millimeter, far below tap accuracy.
    private func nearestSegmentInsertionIndex(
        for coord: CLLocationCoordinate2D,
        in waypoints: [DraftWaypoint],
        thresholdMeters: Double
    ) -> Int? {
        guard waypoints.count >= 2 else { return nil }
        var bestDistance = Double.infinity
        var bestInsertIndex: Int? = nil
        for i in 0..<(waypoints.count - 1) {
            let d = distance(from: coord, toSegment: waypoints[i].coordinate, waypoints[i + 1].coordinate)
            if d < bestDistance {
                bestDistance = d
                bestInsertIndex = i + 1   // insert between i and i+1
            }
        }
        return bestDistance <= thresholdMeters ? bestInsertIndex : nil
    }

    /// Perpendicular distance in meters from `point` to the line segment
    /// between `a` and `b`. Clamps to segment endpoints when the foot of
    /// the perpendicular falls outside the segment.
    private func distance(from point: CLLocationCoordinate2D,
                          toSegment a: CLLocationCoordinate2D,
                          _ b: CLLocationCoordinate2D) -> Double {
        // Project lat/lon to a local meters plane around `a`. Latitude
        // degrees are ~111km regardless of where on Earth; longitude
        // degrees scale by cos(lat).
        let metersPerLat = 111_320.0
        let metersPerLon = 111_320.0 * cos(a.latitude * .pi / 180)

        let ax = 0.0
        let ay = 0.0
        let bx = (b.longitude - a.longitude) * metersPerLon
        let by = (b.latitude - a.latitude) * metersPerLat
        let px = (point.longitude - a.longitude) * metersPerLon
        let py = (point.latitude - a.latitude) * metersPerLat

        let dx = bx - ax
        let dy = by - ay
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return hypot(px - ax, py - ay)
        }
        var t = ((px - ax) * dx + (py - ay) * dy) / lengthSq
        t = max(0, min(1, t))
        let cx = ax + t * dx
        let cy = ay + t * dy
        return hypot(px - cx, py - cy)
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
        // New trails always start expanded — the user just created it,
        // they want to see waypoints accumulate as they tap the map.
        expandedPathIds.insert(newPath.id)
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

        // Sorter shared by every group. (sortIndex, createdAt) — sortIndex
        // wins; createdAt is the tiebreaker that gives legacy data (all
        // sortIndex == 0) a deterministic order until the next save assigns
        // proper indices.
        func sortPlaces(_ places: [Place]) -> [Place] {
            places.sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
        }

        var grouped: [UUID?: [Place]] = [:]
        for place in existingPlaces { grouped[place.pathId, default: []].append(place) }

        var seedPaths: [DraftPath] = []

        // Named paths first, in stable order.
        for (uuid, name) in existingPathNames.sorted(by: { $0.value < $1.value }) {
            let places = sortPlaces(grouped[uuid] ?? [])
            seedPaths.append(DraftPath(
                id: uuid,
                name: name,
                waypoints: places.map { place in
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
                waypoints: sortPlaces(places).map {
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
                waypoints: sortPlaces(nilGroup).map {
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
        // Start with only the active trail expanded — many-trail layers
        // would otherwise overflow the panel on first open.
        if let cur = currentPathId { expandedPathIds = [cur] }

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

        // Upsert drafts. Write sortIndex from each waypoint's position in
        // path.waypoints so the renderer (orderedSegmentsByPath) draws the
        // line in tap-order on the next launch — fixes the MST shortcut bug
        // where flagging a new endpoint silently rewired the topology.
        for path in paths {
            for (index, draft) in path.waypoints.enumerated() {
                if let existingId = draft.existingPlaceId,
                   let place = existingById[existingId] {
                    place.latitude = draft.latitude
                    place.longitude = draft.longitude
                    place.name = draft.name.isEmpty ? "Waypoint" : draft.name
                    place.isWaypointEndpoint = draft.isEndpoint
                    place.pathId = path.id
                    place.sortIndex = index
                } else {
                    let new = Place(
                        name: draft.name.isEmpty ? "Waypoint" : draft.name,
                        latitude: draft.latitude,
                        longitude: draft.longitude
                    )
                    new.isWaypointEndpoint = draft.isEndpoint
                    new.pathId = path.id
                    new.sortIndex = index
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
