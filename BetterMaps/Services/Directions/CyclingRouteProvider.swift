import Foundation
import CoreLocation

/// One bike-only routing question.
struct CyclingRouteRequest: Sendable {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    let style: CyclingStyle
    let departure: Date
}

/// Plans a door-to-door cycling route. The result is an `Itinerary` with a
/// single `.bike` leg so it flows through the same UI as transit journeys.
protocol CyclingRouteProvider: Sendable {
    func route(_ request: CyclingRouteRequest) async throws -> Itinerary
}
