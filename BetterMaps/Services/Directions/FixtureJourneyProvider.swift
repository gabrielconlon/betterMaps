import Foundation
import CoreLocation

/// Debug/test only. Two synthetic Heuston → Dún Laoghaire options built in
/// code (Luas + DART with one change, and a direct bus), timed relative to
/// `request.time`. Defined unconditionally so the live-provider stub can
/// fall back to it; `JourneyProviderFactory` only picks it under
/// `-UITestFakeDirections`.
struct FixtureJourneyProvider: JourneyProvider {
    func plan(_ request: JourneyRequest) async throws -> [Itinerary] {
        let prefs = request.preferences
        guard prefs.maxTransfers > 0 else { return [] }
        let allowed = prefs.allowedTransitModes
        return Self.itineraries(anchor: request.time, arriveBy: request.arriveBy).filter { itinerary in
            itinerary.transitLegs.allSatisfy { allowed.contains($0.mode) }
        }
    }

    // MARK: - Fixture geometry

    private static let heuston = CLLocationCoordinate2D(latitude: 53.3464, longitude: -6.2923)
    private static let abbeyStreet = CLLocationCoordinate2D(latitude: 53.3485, longitude: -6.2585)
    private static let taraStreet = CLLocationCoordinate2D(latitude: 53.3473, longitude: -6.2544)
    private static let pearse = CLLocationCoordinate2D(latitude: 53.3433, longitude: -6.2492)
    private static let blackrock = CLLocationCoordinate2D(latitude: 53.3017, longitude: -6.1793)
    private static let dunLaoghaireStation = CLLocationCoordinate2D(latitude: 53.2946, longitude: -6.1341)
    private static let dunLaoghaire = CLLocationCoordinate2D(latitude: 53.2938, longitude: -6.1353)

    static func itineraries(anchor: Date, arriveBy: Bool) -> [Itinerary] {
        [railOption(anchor: anchor, arriveBy: arriveBy), busOption(anchor: anchor, arriveBy: arriveBy)]
    }

    /// Walk 3 › Luas Red 13 › Walk 3 › DART 26 › Walk 3 (48 min, 1 change).
    private static func railOption(anchor: Date, arriveBy: Bool) -> Itinerary {
        let total = 48 * 60
        let start = arriveBy ? anchor.addingTimeInterval(TimeInterval(-total)) : anchor.addingTimeInterval(4 * 60)
        var cursor = start
        func leg(_ id: String, _ mode: TransitMode, minutes: Int, route: String? = nil, headsign: String? = nil,
                 from: String, to: String, fromStop: String? = nil, toStop: String? = nil,
                 coords: [CLLocationCoordinate2D], stops: [IntermediateStop] = []) -> Leg {
            let legStart = cursor
            let legEnd = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            cursor = legEnd
            return Leg(id: id, mode: mode, routeShortName: route, headsign: headsign,
                       fromName: from, toName: to, fromStopId: fromStop, toStopId: toStop,
                       start: legStart, end: legEnd, durationSeconds: minutes * 60,
                       coordinates: coords, intermediateStops: stops)
        }
        let legs = [
            leg("fx-rail-1", .walk, minutes: 3, from: "Heuston Station", to: "Heuston",
                coords: [heuston, CLLocationCoordinate2D(latitude: 53.3466, longitude: -6.2918)]),
            leg("fx-rail-2", .luas, minutes: 13, route: "Red", headsign: "The Point",
                from: "Heuston", to: "Abbey Street", fromStop: "8220GA00406", toStop: "8220GA00408",
                coords: [CLLocationCoordinate2D(latitude: 53.3466, longitude: -6.2918),
                         CLLocationCoordinate2D(latitude: 53.3471, longitude: -6.2800),
                         CLLocationCoordinate2D(latitude: 53.3478, longitude: -6.2680), abbeyStreet],
                stops: [IntermediateStop(name: "James's", time: start.addingTimeInterval(6 * 60), stopId: nil),
                        IntermediateStop(name: "Smithfield", time: start.addingTimeInterval(10 * 60), stopId: nil),
                        IntermediateStop(name: "Jervis", time: start.addingTimeInterval(14 * 60), stopId: "8220GA00404")]),
            leg("fx-rail-3", .walk, minutes: 3, from: "Abbey Street", to: "Tara Street",
                coords: [abbeyStreet, taraStreet]),
            leg("fx-rail-4", .dart, minutes: 26, route: "DART", headsign: "Greystones",
                from: "Tara Street", to: "Dún Laoghaire", fromStop: "8220IR0025", toStop: "8250IR0033",
                coords: [taraStreet, pearse, blackrock, dunLaoghaireStation],
                stops: [IntermediateStop(name: "Pearse", time: start.addingTimeInterval(21 * 60), stopId: nil),
                        IntermediateStop(name: "Lansdowne Road", time: start.addingTimeInterval(25 * 60), stopId: nil),
                        IntermediateStop(name: "Sandymount", time: start.addingTimeInterval(28 * 60), stopId: nil),
                        IntermediateStop(name: "Booterstown", time: start.addingTimeInterval(32 * 60), stopId: nil),
                        IntermediateStop(name: "Blackrock", time: start.addingTimeInterval(36 * 60), stopId: nil),
                        IntermediateStop(name: "Seapoint", time: start.addingTimeInterval(39 * 60), stopId: nil),
                        IntermediateStop(name: "Salthill and Monkstown", time: start.addingTimeInterval(42 * 60), stopId: nil)]),
            leg("fx-rail-5", .walk, minutes: 3, from: "Dún Laoghaire", to: "Dún Laoghaire",
                coords: [dunLaoghaireStation, dunLaoghaire]),
        ]
        return Itinerary(id: "fixture-rail", legs: legs, start: start, end: cursor,
                         durationSeconds: total, transfers: 1, walkSeconds: 9 * 60, bikeSeconds: 0)
    }

    /// Walk 4 › Bus 145 51 › Walk 2 (57 min, no changes).
    private static func busOption(anchor: Date, arriveBy: Bool) -> Itinerary {
        let total = 57 * 60
        let start = arriveBy ? anchor.addingTimeInterval(TimeInterval(-total)) : anchor.addingTimeInterval(7 * 60)
        let walkEnd = start.addingTimeInterval(4 * 60)
        let busEnd = walkEnd.addingTimeInterval(51 * 60)
        let end = busEnd.addingTimeInterval(2 * 60)
        let stopA = CLLocationCoordinate2D(latitude: 53.3459, longitude: -6.2935)
        let stopB = CLLocationCoordinate2D(latitude: 53.2951, longitude: -6.1362)
        let legs = [
            Leg(id: "fx-bus-1", mode: .walk, fromName: "Heuston Station", toName: "Heuston Station, stop 4495",
                start: start, end: walkEnd, durationSeconds: 4 * 60, coordinates: [heuston, stopA]),
            Leg(id: "fx-bus-2", mode: .bus, routeShortName: "145", headsign: "Kilmacanogue",
                fromName: "Heuston Station, stop 4495", toName: "Dún Laoghaire, Marine Road",
                fromStopId: "8220DB004495", toStopId: "8250DB002039",
                start: walkEnd, end: busEnd, durationSeconds: 51 * 60,
                coordinates: [stopA, CLLocationCoordinate2D(latitude: 53.3380, longitude: -6.2600),
                              CLLocationCoordinate2D(latitude: 53.3290, longitude: -6.2300),
                              CLLocationCoordinate2D(latitude: 53.3100, longitude: -6.1900), stopB],
                intermediateStops: [
                    IntermediateStop(name: "College Green", time: walkEnd.addingTimeInterval(12 * 60), stopId: nil),
                    IntermediateStop(name: "Donnybrook", time: walkEnd.addingTimeInterval(24 * 60), stopId: nil),
                    IntermediateStop(name: "Stillorgan", time: walkEnd.addingTimeInterval(36 * 60), stopId: nil),
                ]),
            Leg(id: "fx-bus-3", mode: .walk, fromName: "Dún Laoghaire, Marine Road", toName: "Dún Laoghaire",
                start: busEnd, end: end, durationSeconds: 2 * 60, coordinates: [stopB, dunLaoghaire]),
        ]
        return Itinerary(id: "fixture-bus", legs: legs, start: start, end: end,
                         durationSeconds: total, transfers: 0, walkSeconds: 6 * 60, bikeSeconds: 0)
    }
}
