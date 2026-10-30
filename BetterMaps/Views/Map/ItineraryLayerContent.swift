import SwiftUI
import MapKit

/// The directions option the user picked: one polyline per leg in the
/// leg's network colour (walks dashed grey), and a marker at the end unless
/// the search's own destination pin already stands there.
/// Draws only from the value snapshot the canvas already holds.
struct ItineraryLayerContent: MapContent {
    let legs: [Leg]
    var showsEndMarker = true

    private static let walkStyle = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [6, 6])
    private static let rideStyle = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

    var body: some MapContent {
        ForEach(legs) { leg in
            if leg.coordinates.count > 1 {
                MapPolyline(coordinates: leg.coordinates)
                    .stroke(TransitColors.leg(for: leg), style: leg.mode == .walk ? Self.walkStyle : Self.rideStyle)
            }
        }
        if showsEndMarker, let last = legs.last, let end = last.coordinates.last {
            Marker(last.toName, systemImage: "flag.fill", coordinate: end)
                .tint(Color.accentColor)
        }
    }
}
