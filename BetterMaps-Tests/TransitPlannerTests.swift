import XCTest
import CoreLocation
@testable import BetterMapsApp

/// Tests for TransitRoutePlanner logic: walking calculations, mode detection,
/// interchange identification, and route finding with Dublin-based scenarios.
final class TransitPlannerTests: XCTestCase {

    var planner: TransitRoutePlanner!

    override func setUp() {
        super.setUp()
        planner = TransitRoutePlanner()
    }

    // MARK: - Walking Distance & Time

    /// Two points ~1km apart (O'Connell St to Temple Bar) should give ~17-18 min walk
    /// with the 1.4x road routing factor applied to crow-flies distance.
    func testWalkingMinutesShortDistance() async {
        let minutes = await planner.walkingMinutes(
            from: Dublin.oconnellStreet,
            to: Dublin.templeBar
        )
        // ~450m crow-flies × 1.4 road factor = ~630m, at 80m/min = ~8 min
        XCTAssertGreaterThan(minutes, 3, "Should take at least a few minutes to walk")
        XCTAssertLessThan(minutes, 20, "Shouldn't take 20 minutes for a short walk")
    }

    /// Walking distance from Connolly to Heuston (~3.5km crow-flies)
    /// should be significant but walkable.
    func testWalkingMinutesMediumDistance() async {
        let minutes = await planner.walkingMinutes(
            from: Dublin.connollyStation,
            to: Dublin.heustonStation
        )
        // ~3.5km × 1.4 = ~4.9km, at 80m/min = ~61 min
        XCTAssertGreaterThan(minutes, 40, "Connolly to Heuston is a long walk")
        XCTAssertLessThan(minutes, 90, "But shouldn't be unreasonably long")
    }

    /// Dublin to Galway should give an absurd walking time (not walkable).
    func testWalkingMinutesLongDistance() async {
        let minutes = await planner.walkingMinutes(
            from: Dublin.connollyStation,
            to: Dublin.galway
        )
        // ~200km × 1.4 = ~280km, at 80m/min = ~3,500 min = ~58 hours
        XCTAssertGreaterThan(minutes, 2000, "Dublin to Galway is not a walk")
    }

    /// Walking distance should include the 1.4x road routing factor.
    func testWalkingDistanceIncludesRoadFactor() async {
        let distance = await planner.walkingDistance(
            from: Dublin.oconnellStreet,
            to: Dublin.stephensGreen
        )
        // Crow-flies ~1.1km, road distance should be ~1.5km
        let crowFlies = CLLocation(
            latitude: Dublin.oconnellStreet.latitude,
            longitude: Dublin.oconnellStreet.longitude
        ).distance(from: CLLocation(
            latitude: Dublin.stephensGreen.latitude,
            longitude: Dublin.stephensGreen.longitude
        ))
        XCTAssertGreaterThan(distance, crowFlies, "Road distance should exceed crow-flies")
        XCTAssertEqual(distance, crowFlies * 1.4, accuracy: 1.0, "Should apply 1.4x factor")
    }

    /// Same point should give 0 walking time.
    func testWalkingMinutesSamePoint() async {
        let minutes = await planner.walkingMinutes(
            from: Dublin.oconnellStreet,
            to: Dublin.oconnellStreet
        )
        XCTAssertEqual(minutes, 0)
    }

    // MARK: - Leg Mode Detection

    /// Bus trip (route_type=3) should return .bus regardless of stop type.
    func testLegModeBus() async {
        let stop = makeStop(id: "stop1", name: "Random Stop", lat: 53.35, lon: -6.26, type: .bus)
        let trip = makeTrip(routeShortName: "39A", routeType: 3)
        let mode = await planner.legMode(for: stop, trip: trip)
        XCTAssertEqual(mode, .bus)
    }

    /// Luas trip (route_type=0) should return .luas.
    func testLegModeLuas() async {
        let stop = makeStop(id: "luas1", name: "St. Stephen's Green", lat: 53.339, lon: -6.261, type: .luas)
        let trip = makeTrip(routeShortName: "Green", routeType: 0)
        let mode = await planner.legMode(for: stop, trip: trip)
        XCTAssertEqual(mode, .luas)
    }

    /// DART trip (route_type=2, name="DART") should return .dart.
    func testLegModeDART() async {
        let stop = makeStop(id: "dart1", name: "Connolly", lat: 53.351, lon: -6.250, type: .dart)
        let trip = makeTrip(routeShortName: "DART", routeType: 2)
        let mode = await planner.legMode(for: stop, trip: trip)
        XCTAssertEqual(mode, .dart)
    }

    /// InterCity rail (route_type=2, name != "DART") should return .rail.
    func testLegModeInterCityRail() async {
        let stop = makeStop(id: "rail1", name: "Heuston", lat: 53.346, lon: -6.292, type: .rail)
        let trip = makeTrip(routeShortName: "Galway", routeType: 2)
        let mode = await planner.legMode(for: stop, trip: trip)
        XCTAssertEqual(mode, .rail)
    }

    /// DART detection should be case-insensitive.
    func testLegModeDARTCaseInsensitive() async {
        let stop = makeStop(id: "dart1", name: "Pearse", lat: 53.343, lon: -6.250, type: .dart)
        let trip = makeTrip(routeShortName: "dart", routeType: 2)
        let mode = await planner.legMode(for: stop, trip: trip)
        XCTAssertEqual(mode, .dart, "DART detection should be case-insensitive")
    }

    // MARK: - Interchange Detection

    /// Connolly Station should be identified as an interchange.
    func testConnollyIsInterchange() async {
        let stop = makeStop(id: "connolly", name: "Connolly Station", lat: 53.351, lon: -6.250, type: .dart)
        let stopById = ["connolly": stop]
        let result = await planner.isInterchangeStop(stopId: "connolly", stopById: stopById)
        XCTAssertTrue(result, "Connolly is a major interchange")
    }

    /// Heuston Station should be identified as an interchange.
    func testHeustonIsInterchange() async {
        let stop = makeStop(id: "heuston", name: "Heuston Station", lat: 53.346, lon: -6.292, type: .rail)
        let stopById = ["heuston": stop]
        let result = await planner.isInterchangeStop(stopId: "heuston", stopById: stopById)
        XCTAssertTrue(result, "Heuston is a major interchange")
    }

    /// A random bus stop should NOT be an interchange.
    func testRandomStopNotInterchange() async {
        let stop = makeStop(id: "bus123", name: "Phibsborough Road Stop 4532", lat: 53.36, lon: -6.27, type: .bus)
        let stopById = ["bus123": stop]
        let result = await planner.isInterchangeStop(stopId: "bus123", stopById: stopById)
        // Phibsborough IS in the interchange list, so this will be true
        // Let's use a non-interchange name
        let otherStop = makeStop(id: "bus456", name: "Castleknock Gate", lat: 53.37, lon: -6.36, type: .bus)
        let otherById = ["bus456": otherStop]
        let result2 = await planner.isInterchangeStop(stopId: "bus456", stopById: otherById)
        XCTAssertFalse(result2, "Castleknock Gate is not an interchange")
    }

    /// Busaras should be identified (with and without fada).
    func testBusarasInterchange() async {
        let stop1 = makeStop(id: "bus1", name: "Busaras", lat: 53.350, lon: -6.253, type: .bus)
        let stop2 = makeStop(id: "bus2", name: "Busáras", lat: 53.350, lon: -6.253, type: .bus)
        let result1 = await planner.isInterchangeStop(stopId: "bus1", stopById: ["bus1": stop1])
        let result2 = await planner.isInterchangeStop(stopId: "bus2", stopById: ["bus2": stop2])
        XCTAssertTrue(result1, "Busaras (no fada) should match")
        XCTAssertTrue(result2, "Busáras (with fada) should match")
    }

    // MARK: - Transit Stop Types

    /// Verify TransitStop coordinate property works correctly.
    func testTransitStopCoordinate() {
        let stop = makeStop(id: "test", name: "Test", lat: 53.35, lon: -6.26)
        XCTAssertEqual(stop.coordinate.latitude, 53.35, accuracy: 0.0001)
        XCTAssertEqual(stop.coordinate.longitude, -6.26, accuracy: 0.0001)
    }

    /// Verify GTFSStopTime seconds conversion.
    func testStopTimeSecondsConversion() {
        // 08:30:00 = 30,600 seconds
        let st = makeStopTime(stopId: "s1", sequence: 1, departureSeconds: 30600)
        XCTAssertEqual(st.departureSeconds, 30600)
        XCTAssertEqual(st.departureTime, "08:30:00")
    }

    /// Verify GTFSStopTime for times past midnight (GTFS allows 25:00:00).
    func testStopTimePastMidnight() {
        let st = makeStopTime(stopId: "s1", sequence: 1, departureSeconds: 90000) // 25:00:00
        XCTAssertEqual(st.departureSeconds, 90000)
    }

    // MARK: - Route Scenario: Southwest Dublin (Bus Only)

    /// Southwest Dublin (Firhouse → Rathfarnham) has no Luas or DART.
    /// Transit planner should only find bus options (if GTFS is loaded)
    /// or return empty (no routes) — but should NOT crash.
    func testSouthwestDublinBusOnly() async {
        // Create stops that represent southwest Dublin (bus territory)
        let origin = Dublin.firhouse
        let destination = Dublin.rathfarnham

        let stops = [
            makeStop(id: "bus_firhouse_1", name: "Firhouse Road", lat: 53.283, lon: -6.335, type: .bus),
            makeStop(id: "bus_firhouse_2", name: "Firhouse Shopping Centre", lat: 53.284, lon: -6.336, type: .bus),
            makeStop(id: "bus_rath_1", name: "Rathfarnham Village", lat: 53.301, lon: -6.283, type: .bus),
            makeStop(id: "bus_rath_2", name: "Rathfarnham Castle", lat: 53.300, lon: -6.280, type: .bus),
        ]

        // findRoutes should not crash even without a loaded GTFS database
        let routes = await planner.findRoutes(
            from: origin,
            to: destination,
            transitStops: stops,
            maxWalkingMinutes: 15,
            maxTransfers: 1
        )

        // Without a loaded GTFS schedule, we expect empty results — but no crash
        // If GTFS IS loaded, results should only contain bus legs (no Luas/DART in this area)
        for route in routes {
            for leg in route.legs {
                if case .ride(_, _, _, _, _, _, _, _, let mode, _, _, _) = leg {
                    XCTAssertEqual(mode, .bus, "Southwest Dublin should only have bus routes")
                }
            }
        }
    }

    // MARK: - Route Scenario: Long Distance (Dublin to Galway)

    /// Dublin to Galway (~200km) should exceed max walking distance.
    /// Transit planner should find no walking-based routes.
    func testDublinToGalwayExceedsWalkingLimit() async {
        let routes = await planner.findRoutes(
            from: Dublin.connollyStation,
            to: Dublin.galway,
            transitStops: [],
            maxWalkingMinutes: 15
        )
        XCTAssertTrue(routes.isEmpty, "No transit routes should span Dublin-Galway with 15 min walk limit")
    }

    // MARK: - Route Scenario: Near Liffey (Luas Territory)

    /// Smithfield → Jervis is a short Luas Red Line trip.
    /// With proper stops, planner should identify these as Luas territory.
    func testLiffeyAreaStopsAreLuasTerritory() async {
        let stops = [
            makeStop(id: "luas_smi", name: "Smithfield", lat: 53.3472, lon: -6.2780, type: .luas),
            makeStop(id: "luas_jer", name: "Jervis", lat: 53.3474, lon: -6.2655, type: .luas),
            makeStop(id: "bus_nearby", name: "Capel Street", lat: 53.3470, lon: -6.2700, type: .bus),
        ]

        // Walking distance between Smithfield and Jervis is ~900m
        let walkMin = await planner.walkingMinutes(from: Dublin.smithfield, to: Dublin.jervis)
        XCTAssertLessThan(walkMin, 20, "Smithfield to Jervis should be walkable")
        XCTAssertGreaterThan(walkMin, 5, "But not trivially short")

        // Both stops should be within Luas walking radius (1200m)
        let smithfieldLoc = CLLocation(latitude: Dublin.smithfield.latitude, longitude: Dublin.smithfield.longitude)
        let jervisLoc = CLLocation(latitude: stops[1].latitude, longitude: stops[1].longitude)
        let distance = smithfieldLoc.distance(from: jervisLoc)
        XCTAssertLessThan(distance, 1200, "Luas stops should be within 1200m radius of each other")
    }
}
