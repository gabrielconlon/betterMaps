import SwiftUI
import MapKit

/// The fastest option per network, drawn so the user can compare where each
/// one goes before picking. A little thinner than the picked journey
/// (`ItineraryLayerContent`), which replaces these once chosen, but in the
/// same deep route colours over a casing: the first cut (3 pt, pastel, 55 %)
/// was close to invisible on the street grid. All casings go down before any
/// colour so one option's casing never cuts across another's line.
/// Draws only from the value snapshot the canvas already holds.
struct DirectionsPreviewContent: MapContent {
    let itineraries: [[Leg]]

    private static let style = StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
    private static let casing = StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
    private static let opacity = 0.85

    /// A leg tagged with its option's index: two options can share a leg id.
    private struct PreviewLeg: Identifiable {
        let id: String
        let leg: Leg
    }

    private var legs: [PreviewLeg] {
        itineraries.enumerated().flatMap { index, legs in
            legs.filter { $0.coordinates.count > 1 }
                .map { PreviewLeg(id: "\(index)-\($0.id)", leg: $0) }
        }
    }

    var body: some MapContent {
        ForEach(legs) { item in
            MapPolyline(coordinates: item.leg.coordinates)
                .stroke(TransitColors.routeCasing, style: Self.casing)
        }
        ForEach(legs) { item in
            MapPolyline(coordinates: item.leg.coordinates)
                .stroke(TransitColors.routeLeg(for: item.leg).opacity(Self.opacity), style: Self.style)
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
