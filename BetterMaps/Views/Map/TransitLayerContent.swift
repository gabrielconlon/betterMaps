import SwiftUI
import MapKit

/// Transit network lines, the highlighted favorite route, and stop pins.
/// Renders only the value arrays `TransitLayerStore` has already culled.
struct TransitLayerContent: MapContent {
    let stops: [TransitStop]
    let lines: [TransitLine]
    let highlightedRoute: [[CLLocationCoordinate2D]]?
    /// Pin sizes for the span the visible stops were culled for.
    let zoomBucket: TransitZoomBucket
    /// Settled camera heading, so bus stop direction arrows stay true when
    /// the map is rotated.
    var mapHeading: Double = 0
    let onTapStop: (TransitStop) -> Void

    var body: some MapContent {
        ForEach(lines) { line in
            MapPolyline(coordinates: line.coordinates)
                .stroke(TransitColors.line(for: line), lineWidth: 3)
        }

        if let highlightedRoute {
            ForEach(Array(highlightedRoute.enumerated()), id: \.offset) { _, coords in
                MapPolyline(coordinates: coords)
                    .stroke(TransitColors.highlightedRoute, lineWidth: 5)
            }
        }

        // Dots: no title, no gesture, no hit area (taps near one are
        // resolved by the map's tap handler). Only full pins carry a title.
        ForEach(stops) { stop in
            let size = zoomBucket.size(for: stop.kind)
            if size == .dot {
                Annotation("", coordinate: stop.coordinate) {
                    TransitStopPin(stop: stop, size: .dot)
                }
                .annotationTitles(.hidden)
            } else {
                Annotation(size == .full ? stop.name : "", coordinate: stop.coordinate) {
                    TransitStopPin(stop: stop, size: size, mapHeading: mapHeading)
                        .onTapGesture { onTapStop(stop) }
                }
            }
        }
    }
}
