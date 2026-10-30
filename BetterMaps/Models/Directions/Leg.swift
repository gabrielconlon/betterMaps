import Foundation
import CoreLocation

/// A stop a transit leg passes through without the rider getting off.
struct IntermediateStop: Hashable, Sendable {
    let name: String
    let time: Date
    /// Bare GTFS stop id matching `TransitStop.id`, when the planner gave one.
    let stopId: String?
}

/// One segment of an `Itinerary`: a walk, a ride, or a cycle between two
/// named points. Identity is `id` alone, as with `TransitLine`, because
/// `CLLocationCoordinate2D` is not Hashable.
struct Leg: Identifiable, Hashable, Sendable {
    let id: String
    let mode: TransitMode
    /// "39A", "Red", "DART"; nil for walk and bike.
    let routeShortName: String?
    let headsign: String?
    let fromName: String
    let toName: String
    /// Bare ids matching `TransitStop.id`; nil at a street address.
    let fromStopId: String?
    let toStopId: String?
    let start: Date
    let end: Date
    let durationSeconds: Int
    let coordinates: [CLLocationCoordinate2D]
    let intermediateStops: [IntermediateStop]
    /// True when `start`/`end` come from a live feed rather than the timetable.
    let isRealtime: Bool

    init(id: String, mode: TransitMode, routeShortName: String? = nil, headsign: String? = nil,
         fromName: String, toName: String, fromStopId: String? = nil, toStopId: String? = nil,
         start: Date, end: Date, durationSeconds: Int,
         coordinates: [CLLocationCoordinate2D] = [], intermediateStops: [IntermediateStop] = [],
         isRealtime: Bool = false) {
        self.id = id
        self.mode = mode
        self.routeShortName = routeShortName
        self.headsign = headsign
        self.fromName = fromName
        self.toName = toName
        self.fromStopId = fromStopId
        self.toStopId = toStopId
        self.start = start
        self.end = end
        self.durationSeconds = durationSeconds
        self.coordinates = coordinates
        self.intermediateStops = intermediateStops
        self.isRealtime = isRealtime
    }

    static func == (lhs: Leg, rhs: Leg) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
