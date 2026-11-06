import Foundation
import CoreLocation

/// One bike-only routing question.
struct CyclingRouteRequest: Sendable {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    let style: CyclingStyle
    /// The planned time: when to leave, or with `arriveBy` when to be there.
    let time: Date
    var arriveBy: Bool = false

    /// When a ride of `durationSeconds` starts and ends for this request.
    /// BRouter only gives a duration, so an arrive-by ride is placed to end
    /// at `time` rather than start there.
    func window(durationSeconds: Int) -> (start: Date, end: Date) {
        let duration = TimeInterval(durationSeconds)
        return arriveBy ? (time.addingTimeInterval(-duration), time) : (time, time.addingTimeInterval(duration))
    }
}

/// Plans a door-to-door cycling route. The result is an `Itinerary` with a
/// single `.bike` leg so it flows through the same UI as transit journeys.
protocol CyclingRouteProvider: Sendable {
    func route(_ request: CyclingRouteRequest) async throws -> Itinerary
}
