import SwiftUI
import MapKit

/// The directions option the user picked: one polyline per leg in the
/// leg's deep route colour (walks dashed slate) over a casing, and a marker
/// at the end unless the search's own destination pin already stands there.
/// Casings go down first so a leg's casing never covers the leg before it.
/// Draws only from the value snapshot the canvas already holds.
struct ItineraryLayerContent: MapContent {
    let legs: [Leg]
    var showsEndMarker = true

    private static let walkStyle = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [2, 8])
    private static let rideStyle = StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)
    private static let walkCasing = StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
    private static let rideCasing = StrokeStyle(lineWidth: 10.5, lineCap: .round, lineJoin: .round)

    private var drawable: [Leg] { legs.filter { $0.coordinates.count > 1 } }

    var body: some MapContent {
        ForEach(drawable) { leg in
            MapPolyline(coordinates: leg.coordinates)
                .stroke(TransitColors.routeCasing, style: leg.mode == .walk ? Self.walkCasing : Self.rideCasing)
        }
        ForEach(drawable) { leg in
            MapPolyline(coordinates: leg.coordinates)
                .stroke(TransitColors.routeLeg(for: leg), style: leg.mode == .walk ? Self.walkStyle : Self.rideStyle)
        }
        if showsEndMarker, let last = legs.last, let end = last.coordinates.last {
            Marker(last.toName, systemImage: "flag.fill", coordinate: end)
                .tint(Color.accentColor)
        }
    }
}
