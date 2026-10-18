import SwiftUI
import MapKit

/// Transit network lines and stop pins. Still fed by `TransitMapState`
/// (Phase 2b replaces the data source); this is the old MapTabView rendering
/// moved verbatim onto value inputs.
struct TransitLayerContent: MapContent {
    let stops: [TransitStop]
    let showTransitStops: Set<TransitStop.TransitStopType>
    let luasRedShapeLines: [[CLLocationCoordinate2D]]
    let luasGreenShapeLines: [[CLLocationCoordinate2D]]
    let dartShapeLines: [[CLLocationCoordinate2D]]
    let railShapeLines: [[CLLocationCoordinate2D]]
    let luasRedStopIds: Set<String>
    let luasGreenStopIds: Set<String>
    let size: AnnotationSize
    let onTapStop: (TransitStop) -> Void

    var body: some MapContent {
        // Luas route lines (from GTFS shapes — accurate track geometry)
        if showTransitStops.contains(.luas) {
            ForEach(Array(luasRedShapeLines.enumerated()), id: \.offset) { _, coords in
                MapPolyline(coordinates: coords)
                    .stroke(TransitColors.luasRedLayer, lineWidth: 3)
            }
            ForEach(Array(luasGreenShapeLines.enumerated()), id: \.offset) { _, coords in
                MapPolyline(coordinates: coords)
                    .stroke(TransitColors.layer(.luas), lineWidth: 3)
            }
        }

        // DART lines (orange) — only the Dublin coastal line
        if showTransitStops.contains(.dart) {
            ForEach(Array(dartShapeLines.enumerated()), id: \.offset) { _, coords in
                MapPolyline(coordinates: coords)
                    .stroke(TransitColors.layer(.dart), lineWidth: 3)
            }
        }

        // Irish Rail lines (purple) — Commuter, InterCity (non-DART)
        if showTransitStops.contains(.rail) {
            ForEach(Array(railShapeLines.enumerated()), id: \.offset) { _, coords in
                MapPolyline(coordinates: coords)
                    .stroke(TransitColors.layer(.rail), lineWidth: 3)
            }
        }

        // Transit stop annotations (toggled layer). Dots carry no title but
        // stay tappable — the pin itself provides a 24pt hit area.
        ForEach(stops) { stop in
            Annotation(size == .dot ? "" : stop.name, coordinate: stop.coordinate) {
                TransitStopPin(stop: stop, size: size, colorOverride: pinColor(for: stop))
                    .onTapGesture { onTapStop(stop) }
            }
        }
    }

    /// Pin color for a stop. `nil` keeps the stop type's default; only Luas
    /// stops are overridden so the pin matches its LINE color (Red vs Green),
    /// like DART (peach) / Rail (lilac) where pin = line.
    private func pinColor(for stop: TransitStop) -> Color? {
        guard stop.type == .luas else { return nil }
        if luasRedStopIds.contains(stop.id) { return TransitColors.luasRedPin }
        if luasGreenStopIds.contains(stop.id) { return TransitColors.luasGrnPin }
        return nil
    }
}
