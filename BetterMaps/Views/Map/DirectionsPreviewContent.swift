import SwiftUI
import MapKit

/// The fastest option per network, drawn faintly so the user can compare
/// where each one goes before picking. Thinner and paler than the picked
/// journey (`ItineraryLayerContent`), which replaces these once chosen.
/// Draws only from the value snapshot the canvas already holds.
struct DirectionsPreviewContent: MapContent {
    let itineraries: [[Leg]]

    private static let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
    private static let opacity = 0.55

    var body: some MapContent {
        ForEach(Array(itineraries.enumerated()), id: \.offset) { _, legs in
            ForEach(legs) { leg in
                if leg.coordinates.count > 1 {
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(TransitColors.leg(for: leg).opacity(Self.opacity), style: Self.style)
                }
            }
        }
    }
}

/// Where the search starts and ends: a red pin on the destination and, when
/// the journey does not start where the user is, a small circle on the
/// start. The user's own location is already on the map.
struct DirectionsEndpointsContent: MapContent {
    let endpoints: DirectionsEndpoints

    var body: some MapContent {
        Marker("Destination", systemImage: "mappin", coordinate: endpoints.destination)
            .tint(.red)
            .annotationTitles(.hidden)
        if let origin = endpoints.origin {
            Annotation("Start", coordinate: origin, anchor: .center) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .accessibilityLabel("Starting point")
            }
            .annotationTitles(.hidden)
        }
    }
}
