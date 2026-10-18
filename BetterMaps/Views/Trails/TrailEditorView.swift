import SwiftUI
import SwiftData
import MapKit

/// Full-screen trail editor (Flow: one focused mode, no modal interruptions
/// mid-draw).
///
/// - Long-press the map to add a point (inserted mid-line when near a segment).
/// - Tap a handle to select it; drag a handle to move it (one undo step).
/// - The selection bar deletes (undoable via toast), marks start/end, or
///   deselects. There is no destructive gesture without an undo.
/// - "Snap to paths" follows walking routes between points; failed segments
///   draw dashed.
///
/// The editor never dismisses itself: it calls `onFinish` with the saved
/// trail on Done, or `nil` on cancel/discard/keep-draft, and the presenter
/// closes it.
struct TrailEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ToastCenter.self) private var appToasts: ToastCenter?

    let layer: Layer
    let trail: Trail?
    let onFinish: (Trail?) -> Void

    @State private var draft: TrailDraft
    /// Baseline for "has changes": the trail as loaded, or the resumed draft.
    @State private var original: TrailDraft
    @State private var selectedId: UUID?
    @State private var draggingId: UUID?
    @State private var camera: MapCameraPosition
    /// Snap results keyed by `TrailSnapService.cacheKey` of each point pair.
    @State private var snapResults: [String: TrailGeometry.Segment] = [:]
    @State private var isSnapping = false
    @State private var snapImmediately = false
    @State private var isSaving = false
    @State private var showCancelDialog = false
    @State private var addCount = 0
    @State private var removeCount = 0
    /// The editor covers the whole screen, so in-editor toasts render here.
    @State private var localToasts = ToastCenter()

    private static let snapService = TrailSnapService()
    private static let snapDebounce: Duration = .milliseconds(600)

    /// - Parameters:
    ///   - layer: the waypoint-path layer the trail belongs to.
    ///   - trail: the trail to edit, or nil to draw a new one.
    ///   - resuming: a kept draft to start from. When nil, a draft kept in
    ///     `TrailDraftStore` for the same layer and trail is resumed.
    ///   - onFinish: called once with the saved trail, or nil when the user
    ///     leaves without saving.
    init(layer: Layer, trail: Trail?, resuming: TrailDraft? = nil, onFinish: @escaping (Trail?) -> Void) {
        self.layer = layer
        self.trail = trail
        self.onFinish = onFinish
        let kept = resuming ?? TrailDraftStore.shared.pending(layerId: layer.id, trailId: trail?.id)?.draft
        let initial = kept ?? trail.map { TrailDraft(trail: $0, places: layer.places ?? []) } ?? TrailDraft()
        _draft = State(initialValue: initial)
        _original = State(initialValue: initial)
        _camera = State(initialValue: Self.initialCamera(for: initial.coordinates))
    }

    var body: some View {
        ZStack {
            TrailEditorMap(
                draft: $draft,
                selectedId: $selectedId,
                draggingId: $draggingId,
                camera: $camera,
                segments: displaySegments,
                color: Color(hex: layer.colorHex) ?? .red,
                lineWidth: max(3, layer.lineWidth),
                onAdd: addPoint
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TrailEditorStatusBar(
                    name: $draft.name,
                    placeholder: placeholderName,
                    summary: TrailFormat.summary(meters: displayedMeters, points: draft.points.count),
                    isSnapping: isSnapping,
                    onCancel: cancel
                )
                Color.clear
                    .allowsHitTesting(false)
                    .toasts(localToasts)
                floatingStack
                TrailEditorToolbar(
                    canUndo: draft.canUndo,
                    isSnapped: snapBinding,
                    canFinish: draft.points.count >= 2,
                    isSaving: isSaving,
                    onUndo: undo,
                    onDone: finish
                )
            }
        }
        .sensoryFeedback(.impact, trigger: addCount)
        .sensoryFeedback(.impact(weight: .light), trigger: removeCount)
        .sensoryFeedback(.selection, trigger: selectedId) { _, new in new != nil }
        .task(id: SnapKey(enabled: draft.isSnapped, points: draft.points, dragging: draggingId != nil)) {
            await runSnap()
        }
        .confirmationDialog("Leave the trail editor?", isPresented: $showCancelDialog, titleVisibility: .visible) {
            Button("Keep draft") {
                TrailDraftStore.shared.save(draft, layerId: layer.id, trailId: trail?.id)
                onFinish(nil)
            }
            Button("Discard", role: .destructive) {
                TrailDraftStore.shared.clear(layerId: layer.id, trailId: trail?.id)
                onFinish(nil)
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("A kept draft can be resumed from the map.")
        }
    }

    // MARK: - Floating stack (hint, snap caption, selection bar)

    @ViewBuilder
    private var floatingStack: some View {
        VStack(spacing: 8) {
            if draft.points.count < 2 {
                Text(draft.points.isEmpty ? "Long-press the map to add a point" : "Long-press to add the next point")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
            if draft.isSnapped, !isSnapping, failedSegmentCount > 0 {
                Label(failedSegmentCount == 1
                      ? "1 segment couldn't follow a path"
                      : "\(failedSegmentCount) segments couldn't follow a path",
                      systemImage: "line.diagonal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
            if let id = selectedId, let point = draft.points.first(where: { $0.id == id }) {
                SelectionBar(
                    isEndpoint: point.isEndpoint,
                    onDelete: { deletePoint(id) },
                    onToggleEndpoint: { draft.toggleEndpoint(id) },
                    onDeselect: { selectedId = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: selectedId)
    }

    // MARK: - Derived

    private var placeholderName: String {
        trail?.name ?? "Trail \((layer.trails?.count ?? 0) + 1)"
    }

    private var hasChanges: Bool {
        draft.points != original.points || draft.name != original.name || draft.isSnapped != original.isSnapped
    }

    private var pairKeys: [String] {
        let pts = draft.points
        guard pts.count >= 2 else { return [] }
        return (0..<(pts.count - 1)).map { TrailSnapService.cacheKey(pts[$0].coordinate, pts[$0 + 1].coordinate) }
    }

    /// Snap off: one continuous straight line. Snap on: one run per pair,
    /// using the snapped route when known (dashed if it failed) and a
    /// straight placeholder while pending.
    private var displaySegments: [TrailDisplaySegment] {
        let pts = draft.points
        guard pts.count >= 2 else { return [] }
        guard draft.isSnapped else {
            return [TrailDisplaySegment(id: 0, coordinates: pts.map(\.coordinate), dashed: false)]
        }
        let keys = pairKeys
        return keys.indices.map { i in
            if let seg = snapResults[keys[i]] {
                return TrailDisplaySegment(id: i, coordinates: seg.coordinates, dashed: !seg.snapped)
            }
            return TrailDisplaySegment(id: i, coordinates: [pts[i].coordinate, pts[i + 1].coordinate], dashed: false)
        }
    }

    private var displayedMeters: Double {
        draft.isSnapped ? displaySegments.reduce(0) { $0 + $1.meters } : draft.straightMeters
    }

    private var failedSegmentCount: Int {
        pairKeys.filter { snapResults[$0]?.snapped == false }.count
    }

    private var snapBinding: Binding<Bool> {
        Binding(
            get: { draft.isSnapped },
            set: { on in
                if on { snapImmediately = true }
                draft.isSnapped = on
            }
        )
    }

    // MARK: - Actions

    private func addPoint(_ coordinate: CLLocationCoordinate2D) {
        draft.add(coordinate)
        selectedId = nil
        addCount += 1
    }

    private func deletePoint(_ id: UUID) {
        draft.remove(id)
        selectedId = nil
        removeCount += 1
        let depth = draft.undoStack.count
        localToasts.show(
            "Point removed",
            systemImage: "trash",
            action: ToastAction(label: "Undo") {
                // Only undo if nothing else was edited since; otherwise the
                // top of the stack is a different change.
                guard draft.undoStack.count == depth,
                      !draft.points.contains(where: { $0.id == id }) else { return }
                draft.undo()
            },
            duration: .seconds(4)
        )
    }

    private func undo() {
        draft.undo()
        if let id = selectedId, !draft.points.contains(where: { $0.id == id }) {
            selectedId = nil
        }
        localToasts.dismiss()
    }

    private func cancel() {
        if hasChanges {
            showCancelDialog = true
        } else {
            onFinish(nil)
        }
    }

    private func finish() {
        guard draft.points.count >= 2, !isSaving else { return }
        isSaving = true
        Task {
            let geometry: TrailGeometry
            if draft.isSnapped {
                let keys = pairKeys
                let known = keys.compactMap { snapResults[$0] }
                geometry = known.count == keys.count
                    ? TrailGeometry(segments: known)
                    : await Self.snapService.snap(points: draft.points)
            } else {
                geometry = TrailGeometry.straight(through: draft.coordinates)
            }
            let saved = TrailCommitter.commit(draft, geometry: geometry, to: layer, trail: trail, in: modelContext)
            TrailDraftStore.shared.clear(layerId: layer.id, trailId: trail?.id)
            appToasts?.show(TrailFormat.savedMessage(for: saved))
            isSaving = false
            onFinish(saved)
        }
    }

    // MARK: - Snapping

    private struct SnapKey: Equatable {
        let enabled: Bool
        let points: [TrailPoint]
        let dragging: Bool
    }

    /// Fetches routes for any pair without a result. Debounced after edits;
    /// immediate right after the toggle turns on. Offline, every pair comes
    /// back unsnapped and draws dashed — no error banner.
    private func runSnap() async {
        guard draft.isSnapped, draggingId == nil, draft.points.count >= 2 else {
            isSnapping = false
            return
        }
        let keys = pairKeys
        guard keys.contains(where: { snapResults[$0] == nil }) else {
            isSnapping = false
            return
        }
        if snapImmediately {
            snapImmediately = false
        } else {
            try? await Task.sleep(for: Self.snapDebounce)
            guard !Task.isCancelled else { return }
        }
        isSnapping = true
        let points = draft.points
        let geometry = await Self.snapService.snap(points: points)
        // A cancelled run reports every pending pair as failed; drop it.
        guard !Task.isCancelled else { return }
        for (i, segment) in geometry.segments.enumerated() where i + 1 < points.count {
            snapResults[TrailSnapService.cacheKey(points[i].coordinate, points[i + 1].coordinate)] = segment
        }
        isSnapping = false
    }

    // MARK: - Camera

    private static func initialCamera(for coordinates: [CLLocationCoordinate2D]) -> MapCameraPosition {
        let dublin = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        guard let first = coordinates.first else {
            return .userLocation(fallback: .region(dublin))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 0.005))
        ))
    }
}
