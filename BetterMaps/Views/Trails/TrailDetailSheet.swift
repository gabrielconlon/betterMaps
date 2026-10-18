import SwiftUI
import SwiftData
import MapKit

/// Summary of one trail: name, length, point count, snapped/straight, a
/// static preview, and Edit / Open in Maps / Delete / Hide on map. Present
/// as a sheet; it sets its own `.medium` detent.
struct TrailDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let trail: Trail
    let onEdit: () -> Void
    /// Called after the trail has been deleted from the context.
    let onDelete: (() -> Void)?

    @State private var confirmDelete = false
    /// Set before deleting so no further body pass reads the deleted model.
    @State private var isDeleted = false

    init(trail: Trail, onEdit: @escaping () -> Void, onDelete: (() -> Void)? = nil) {
        self.trail = trail
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    private var places: [Place] {
        (trail.layer?.places ?? [])
            .filter { $0.pathId == trail.pathId }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Stored geometry when present, else straight lines through the places.
    private var lineSegments: [[CLLocationCoordinate2D]] {
        if let geometry = trail.geometry, !geometry.isEmpty {
            return geometry.segments.map(\.coordinates)
        }
        let coords = places.map(\.coordinate)
        return coords.count >= 2 ? [coords] : []
    }

    private var startCoordinate: CLLocationCoordinate2D? {
        places.first?.coordinate ?? lineSegments.first?.first
    }

    private var color: Color {
        Color(hex: trail.layer?.colorHex ?? "") ?? .accentColor
    }

    var body: some View {
        if isDeleted {
            Color.clear.presentationDetents([.medium])
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trail.name.isEmpty ? "Untitled trail" : trail.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(TrailFormat.distance(trail.distanceMeters))
                    Text("·")
                    Text("\(places.count) \(places.count == 1 ? "point" : "points")")
                    Text("·")
                    Label(trail.isSnapped ? "Follows paths" : "Straight lines",
                          systemImage: trail.isSnapped ? "point.topleft.down.to.point.bottomright.curvepath" : "line.diagonal")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            preview
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                Button {
                    onEdit()
                    dismiss()
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)

                Button(action: openStartInMaps) {
                    Label("Directions", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(startCoordinate == nil)
                .accessibilityLabel("Open start in Apple Maps")

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete trail")
            }

            Button {
                TrailCommitter.setVisible(!trail.isVisible, for: trail, in: modelContext)
            } label: {
                Label(trail.isVisible ? "Hide on map" : "Show on map",
                      systemImage: trail.isVisible ? "eye.slash" : "eye")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .confirmationDialog("Delete \(trail.name.isEmpty ? "this trail" : trail.name)?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete trail", role: .destructive) { deleteTrail() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(places.count) points will be removed. This can't be undone.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        let segments = lineSegments
        Map(initialPosition: Self.camera(for: segments.flatMap { $0 }), interactionModes: []) {
            ForEach(segments.indices, id: \.self) { i in
                MapPolyline(coordinates: segments[i])
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let start = startCoordinate {
                Annotation("Start", coordinate: start, anchor: .center) {
                    Circle().fill(color).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func deleteTrail() {
        let target = trail
        if let layerId = target.layer?.id {
            TrailDraftStore.shared.clear(layerId: layerId, trailId: target.id)
        }
        isDeleted = true
        dismiss()
        let onDelete = onDelete
        Task { @MainActor in
            TrailCommitter.delete(target, in: modelContext)
            onDelete?()
        }
    }

    private func openStartInMaps() {
        guard let start = startCoordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: start))
        item.name = trail.name.isEmpty ? "Trail start" : "\(trail.name) start"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private static func camera(for coords: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard let first = coords.first else { return .automatic }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.5, 0.003),
                                   longitudeDelta: max((maxLon - minLon) * 1.5, 0.003))
        ))
    }
}
