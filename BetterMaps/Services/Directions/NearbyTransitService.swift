import Foundation
import CoreLocation

/// A stop near a place, with the routes serving it when the timetable is
/// on the device.
struct NearbyTransit: Hashable, Sendable {
    let stop: TransitStop
    let distanceMeters: Double
    let routes: [TransitRoute]
    /// False when the timetable is not installed: `routes` is then empty
    /// and the UI falls back to the stop's networks.
    let routesKnown: Bool
}

/// Finds the stops around a coordinate for the place cards' "Nearby
/// transit" section. Reads the installed timetable only; it never starts
/// the download (a place card is not the moment to ask for 13 MB).
struct NearbyTransitService: Sendable {
    private let timetable: BusTimetableService

    init(timetable: BusTimetableService = .shared) {
        self.timetable = timetable
    }

    /// Stops within `radiusMeters`, nearest first, at most `limit`.
    func nearby(_ coordinate: CLLocationCoordinate2D, grid: TransitSpatialGrid,
                radiusMeters: Double = 400, limit: Int = 8) async -> [NearbyTransit] {
        let stops = Array(grid.nearest(to: coordinate, within: radiusMeters).prefix(limit))
        guard !stops.isEmpty else { return [] }
        // `currentState()` only opens a file that is already there.
        var ready = false
        if case .ready = await timetable.currentState() { ready = true }
        var result: [NearbyTransit] = []
        result.reserveCapacity(stops.count)
        for stop in stops {
            var routes: [TransitRoute] = []
            var known = false
            if ready, let found = try? await timetable.routes(forStop: stop.id, altIds: stop.altIds) {
                routes = found
                known = true
            }
            result.append(NearbyTransit(stop: stop,
                                        distanceMeters: WaypointGraph.meters(stop.coordinate, coordinate),
                                        routes: routes, routesKnown: known))
        }
        return result
    }
}
