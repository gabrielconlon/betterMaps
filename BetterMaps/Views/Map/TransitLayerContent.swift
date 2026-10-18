import SwiftUI
import MapKit

/// Transit network lines, the highlighted favorite route, and stop pins.
/// Renders only the value arrays `TransitLayerStore` has already culled.
struct TransitLayerContent: MapContent {
    let stops: [TransitStop]
    let lines: [TransitLine]
    let highlightedRoute: [[CLLocationCoordinate2D]]?
    /// Span the visible stops were culled for; picks each stop's pin size.
    let latitudeDelta: Double
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

        // Only full pins carry a title. Dots stay tappable — the pin itself
        // provides a 24pt hit area.
        ForEach(stops) { stop in
            let size = TransitViewportCuller.pinSize(for: stop.kind, latitudeDelta: latitudeDelta)
            Annotation(size == .full ? stop.name : "", coordinate: stop.coordinate) {
                TransitStopPin(stop: stop, size: size)
                    .onTapGesture { onTapStop(stop) }
            }
        }
    }
}

extension TransitLayerContent {
    /// Value snapshot of the transit store the canvas draws.
    struct Inputs {
        var stops: [TransitStop] = []
        var lines: [TransitLine] = []
        var highlightedRoute: [[CLLocationCoordinate2D]]?
        var latitudeDelta: Double = 0.2

        @MainActor
        init(_ store: TransitLayerStore) {
            stops = store.visibleStops
            lines = store.visibleLines
            highlightedRoute = store.highlightedRoute
            latitudeDelta = store.region.span.latitudeDelta
        }
    }
}
