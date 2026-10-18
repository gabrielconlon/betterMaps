import SwiftUI
import MapKit

/// The editor's map: the trail line, one draggable handle per point. A tap
/// on empty map adds a point, or deselects when a point is selected;
/// long-press also adds.
struct TrailEditorMap: View {
    @Binding var draft: TrailDraft
    @Binding var selectedId: UUID?
    @Binding var draggingId: UUID?
    @Binding var camera: MapCameraPosition
    let segments: [TrailDisplaySegment]
    let color: Color
    let lineWidth: Double
    let onAdd: (CLLocationCoordinate2D) -> Void

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                ForEach(segments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(color, style: StrokeStyle(
                            lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                            dash: segment.dashed ? [6, 4] : []
                        ))
                }
                ForEach(draft.points) { point in
                    Annotation("", coordinate: point.coordinate, anchor: .center) {
                        handle(point)
                            .onTapGesture {
                                selectedId = selectedId == point.id ? nil : point.id
                            }
                            // Ported from the old draw view. `.global` because
                            // `.local` is the 44 pt handle frame, which
                            // `proxy.convert` would misread; high priority so
                            // the handle beats the map's own pan gesture.
                            .highPriorityGesture(dragGesture(for: point.id, proxy: proxy))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture(coordinateSpace: .local) { location in
                handleMapTap(at: location, proxy: proxy)
            }
            .gesture(
                // A plain long press has no location; sequencing a zero-distance
                // drag after it captures where the finger is.
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value,
                              let coordinate = proxy.convert(drag.location, from: .local)
                        else { return }
                        onAdd(coordinate)
                    }
            )
        }
    }

    /// Handles have their own tap gesture, but the map's tap can fire for the
    /// same touch; a tap within a handle's 44 pt frame is left to the handle.
    private func handleMapTap(at location: CGPoint, proxy: MapProxy) {
        let onHandle = draft.points.contains { point in
            guard let p = proxy.convert(point.coordinate, to: .local) else { return false }
            return abs(p.x - location.x) <= 22 && abs(p.y - location.y) <= 22
        }
        guard !onHandle else { return }
        if selectedId != nil {
            selectedId = nil
        } else if let coordinate = proxy.convert(location, from: .local) {
            onAdd(coordinate)
        }
    }

    private func dragGesture(for id: UUID, proxy: MapProxy) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if draggingId != id {
                    draft.beginMove()
                    draggingId = id
                    selectedId = id
                }
                if let coordinate = proxy.convert(value.location, from: .global) {
                    draft.move(id, to: coordinate)
                }
            }
            .onEnded { _ in
                draft.endMove()
                draggingId = nil
            }
    }

    @ViewBuilder
    private func handle(_ point: TrailPoint) -> some View {
        let isSelected = selectedId == point.id
        let isDragging = draggingId == point.id
        let dot: CGFloat = isSelected || isDragging ? 20 : 14
        ZStack {
            if isSelected || isDragging {
                Circle()
                    .stroke(color, lineWidth: 3)
                    .frame(width: isDragging ? 38 : 32, height: isDragging ? 38 : 32)
                    .background(Circle().fill(.white.opacity(0.35)))
            }
            Circle()
                .fill(point.isEndpoint ? color : .white)
                .frame(width: dot, height: dot)
                .overlay(Circle().stroke(color, lineWidth: 2))
            if point.isEndpoint {
                Image(systemName: "flag.fill")
                    .font(.system(size: isSelected ? 10 : 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: isDragging ? color.opacity(0.6) : .black.opacity(0.2), radius: isDragging ? 6 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(point.isEndpoint ? "Trail endpoint" : "Trail point")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
