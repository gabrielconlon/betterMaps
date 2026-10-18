import SwiftUI
import MapKit

/// Waypoint-path trails as polylines, one stroke per segment.
struct TrailsLayerContent: MapContent {
    let trails: [TrailLite]

    var body: some MapContent {
        ForEach(trails) { trail in
            let strokeColor = Color(hex: trail.colorHex) ?? .red
            ForEach(Array(trail.segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(strokeColor, lineWidth: trail.lineWidth)
            }
        }
    }
}
