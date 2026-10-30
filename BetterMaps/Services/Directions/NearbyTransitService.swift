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

    /// Stops within `radiusMeters`, nearest first, at most `limit`. The
    /// timetable is asked for every stop's routes at once; the answers are
    /// put back in the grid's nearest-first order.
    func nearby(_ coordinate: CLLocationCoordinate2D, grid: TransitSpatialGrid,
                radiusMeters: Double = 400, limit: Int = 8) async -> [NearbyTransit] {
        let candidates = Array(grid.nearestWithDistance(to: coordinate, within: radiusMeters).prefix(limit))
        guard !candidates.isEmpty else { return [] }
        // `currentState()` only opens a file that is already there.
        var ready = false
        if case .ready = await timetable.currentState() { ready = true }
        guard ready else {
            return candidates.map {
                NearbyTransit(stop: $0.stop, distanceMeters: $0.meters, routes: [], routesKnown: false)
            }
        }

        let timetable = self.timetable
        var byIndex: [Int: NearbyTransit] = [:]
        await withTaskGroup(of: (Int, NearbyTransit).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    var routes: [TransitRoute] = []
                    var known = false
                    if let found = try? await timetable.routes(forStop: candidate.stop.id, altIds: candidate.stop.altIds) {
                        routes = found
                        known = true
                    }
                    return (index, NearbyTransit(stop: candidate.stop, distanceMeters: candidate.meters,
                                                 routes: routes, routesKnown: known))
                }
            }
            for await (index, found) in group { byIndex[index] = found }
        }
        return candidates.indices.compactMap { byIndex[$0] }
    }
}
