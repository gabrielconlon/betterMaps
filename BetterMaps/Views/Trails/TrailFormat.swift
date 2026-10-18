import Foundation
import CoreLocation

/// Shared, locale-aware copy for trail lengths and summaries.
enum TrailFormat {

    /// "2.4 km" / "1.5 mi" / "350 m", following the user's locale.
    static func distance(_ meters: Double) -> String {
        let measurement = Measurement(value: max(0, meters), unit: UnitLength.meters)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .road,
                         numberFormatStyle: .number.precision(.fractionLength(0...1)))
        )
    }

    /// "1.8 km · 12 points"
    static func summary(meters: Double, points: Int) -> String {
        "\(distance(meters)) · \(points) \(points == 1 ? "point" : "points")"
    }

    /// Peak-end confirmation shown after Done: "Trail saved · 2.4 km".
    @MainActor
    static func savedMessage(for trail: Trail) -> String {
        "Trail saved · \(distance(trail.distanceMeters))"
    }
}

/// One drawable run of the editor's line. Dashed only where a snap failed.
struct TrailDisplaySegment: Identifiable, Equatable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let dashed: Bool

    static func == (lhs: TrailDisplaySegment, rhs: TrailDisplaySegment) -> Bool {
        lhs.id == rhs.id && lhs.dashed == rhs.dashed
            && lhs.coordinates.count == rhs.coordinates.count
            && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }

    var meters: Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(coordinates.count - 1) {
            total += WaypointGraph.meters(coordinates[i], coordinates[i + 1])
        }
        return total
    }
}
