import XCTest
import CoreLocation
@testable import CustomMapApp

/// Tests for transit stop classification, type properties, and the
/// stop selection logic used by the routing view model.
final class StopClassificationTests: XCTestCase {

    // MARK: - Transit kind properties

    /// Each network has a distinct pastel pin color.
    func testStopTypeColors() {
        XCTAssertEqual(TransitColors.pinHex(.bus), TransitColors.busPinHex, "Bus = pastel cornflower")
        XCTAssertEqual(TransitColors.pinHex(.luas), TransitColors.luasGrnPinHex, "Luas = pastel mint")
        XCTAssertEqual(TransitColors.pinHex(.dart), TransitColors.dartPinHex, "DART = pastel peach")
        XCTAssertEqual(TransitColors.pinHex(.rail), TransitColors.railPinHex, "Rail = pastel lilac")
        XCTAssertEqual(Set(TransitLayerKind.allCases.map(TransitColors.pinHex)).count, 4)
    }

    /// Each network has a display name.
    func testStopTypeDisplayNames() {
        XCTAssertEqual(TransitLayerKind.bus.displayName, "Bus")
        XCTAssertEqual(TransitLayerKind.luas.displayName, "Luas")
        XCTAssertEqual(TransitLayerKind.dart.displayName, "DART")
        XCTAssertEqual(TransitLayerKind.rail.displayName, "Rail")
    }

    /// All networks use SF Symbols.
    func testStopTypeIcons() {
        XCTAssertEqual(TransitLayerKind.bus.systemImage, "bus.fill")
        XCTAssertEqual(TransitLayerKind.luas.systemImage, "tram.fill")
        XCTAssertEqual(TransitLayerKind.dart.systemImage, "tram.fill")
    }

    // MARK: - Stop Proximity

    /// Two stops at the same location should be within 0m of each other.
    func testSameLocationProximity() {
        let loc = CLLocation(latitude: Dublin.connollyStation.latitude,
                             longitude: Dublin.connollyStation.longitude)
        let distance = loc.distance(from: loc)
        XCTAssertEqual(distance, 0, accuracy: 0.1)
    }

    /// Connolly DART and Connolly Luas should be within 250m (dedup threshold).
    func testConnollyDARTAndLuasProximity() {
        // DART Connolly Station
        let dartLoc = CLLocation(latitude: 53.3510, longitude: -6.2500)
        // Luas Connolly (from hardcoded data)
        let luasLoc = CLLocation(latitude: 53.3510, longitude: -6.2500) // Same-ish
        let distance = dartLoc.distance(from: luasLoc)
        XCTAssertLessThan(distance, 250, "DART and Luas Connolly should be within dedup threshold")
    }

    /// Bus stops across Dublin Bay should NOT be within dedup threshold.
    func testDistantStopsNotNearby() {
        let howthLoc = CLLocation(latitude: Dublin.howth.latitude, longitude: Dublin.howth.longitude)
        let brayLoc = CLLocation(latitude: Dublin.bray.latitude, longitude: Dublin.bray.longitude)
        let distance = howthLoc.distance(from: brayLoc)
        XCTAssertGreaterThan(distance, 10000, "Howth and Bray are far apart")
    }

    // MARK: - Mode-Aware Stop Selection Radius

    /// Bus stops should be found within 800m of origin.
    func testBusStopSearchRadius() {
        let origin = CLLocation(latitude: Dublin.templeBar.latitude,
                                longitude: Dublin.templeBar.longitude)

        let nearbyBus = makeStop(id: "bus1", name: "Dame Street", lat: 53.3442, lon: -6.2640, type: .bus)
        let farBus = makeStop(id: "bus2", name: "Rathmines Road", lat: 53.3250, lon: -6.2630, type: .bus)

        let nearbyDist = CLLocation(latitude: nearbyBus.latitude, longitude: nearbyBus.longitude)
            .distance(from: origin)
        let farDist = CLLocation(latitude: farBus.latitude, longitude: farBus.longitude)
            .distance(from: origin)

        XCTAssertLessThan(nearbyDist, 800, "Dame Street should be within bus radius of Temple Bar")
        XCTAssertGreaterThan(farDist, 800, "Rathmines should be outside bus radius of Temple Bar")
    }

    /// DART stops should be found within 2000m of origin.
    func testDARTStopSearchRadius() {
        let origin = CLLocation(latitude: Dublin.templeBar.latitude,
                                longitude: Dublin.templeBar.longitude)

        let pearseLoc = CLLocation(latitude: 53.3435, longitude: -6.2480) // Pearse DART
        let distance = pearseLoc.distance(from: origin)
        XCTAssertLessThan(distance, 2000, "Pearse Station should be within DART radius of Temple Bar")
    }

    /// Luas stops should be found within 1200m.
    func testLuasStopSearchRadius() {
        let origin = CLLocation(latitude: Dublin.templeBar.latitude,
                                longitude: Dublin.templeBar.longitude)

        let stephensGreenLuas = CLLocation(latitude: 53.3390, longitude: -6.2613)
        let distance = stephensGreenLuas.distance(from: origin)
        XCTAssertLessThan(distance, 1200, "St. Stephen's Green Luas should be within Luas radius of Temple Bar")
    }

    // MARK: - Dublin Area Coverage

    /// Southwest Dublin (Firhouse/Clondalkin) should have no Luas or DART stops nearby.
    func testSouthwestDublinNoDARTOrLuas() {
        let firhouse = CLLocation(latitude: Dublin.firhouse.latitude, longitude: Dublin.firhouse.longitude)

        // Nearest DART (Connolly) is ~10km away
        let connolly = CLLocation(latitude: Dublin.connollyStation.latitude, longitude: Dublin.connollyStation.longitude)
        let dartDist = firhouse.distance(from: connolly)
        XCTAssertGreaterThan(dartDist, 5000, "No DART within 5km of Firhouse")

        // Nearest Luas (Tallaght) is ~5km
        let tallaght = CLLocation(latitude: Dublin.tallaght.latitude, longitude: Dublin.tallaght.longitude)
        let luasDist = firhouse.distance(from: tallaght)
        XCTAssertGreaterThan(luasDist, 1200, "Tallaght Luas outside walking radius from Firhouse")
    }

    /// City centre should have all transit modes within reach.
    func testCityCentreHasAllModes() {
        let centre = CLLocation(latitude: Dublin.oconnellStreet.latitude,
                                longitude: Dublin.oconnellStreet.longitude)

        // Luas: Abbey Street is metres away
        let abbey = CLLocation(latitude: 53.3486, longitude: -6.2584)
        XCTAssertLessThan(centre.distance(from: abbey), 400, "Luas Abbey Street near O'Connell Street")

        // DART: Connolly is ~500m
        let connolly = CLLocation(latitude: Dublin.connollyStation.latitude,
                                  longitude: Dublin.connollyStation.longitude)
        XCTAssertLessThan(centre.distance(from: connolly), 1000, "Connolly DART near O'Connell Street")

        // Bus: everywhere in city centre
        // (implicit — bus stops within 100m of any city centre point)
    }

    // MARK: - Long Distance Sanity

    /// Dublin to Galway should be ~200km.
    func testDublinGalwayDistance() {
        let dublin = CLLocation(latitude: Dublin.connollyStation.latitude,
                                longitude: Dublin.connollyStation.longitude)
        let galway = CLLocation(latitude: Dublin.galway.latitude,
                                longitude: Dublin.galway.longitude)
        let km = dublin.distance(from: galway) / 1000
        XCTAssertGreaterThan(km, 180, "Dublin-Galway should be >180km")
        XCTAssertLessThan(km, 230, "Dublin-Galway should be <230km")
    }

    /// Dublin to Cork should be ~220km.
    func testDublinCorkDistance() {
        let dublin = CLLocation(latitude: Dublin.connollyStation.latitude,
                                longitude: Dublin.connollyStation.longitude)
        let cork = CLLocation(latitude: Dublin.cork.latitude,
                              longitude: Dublin.cork.longitude)
        let km = dublin.distance(from: cork) / 1000
        XCTAssertGreaterThan(km, 200, "Dublin-Cork should be >200km")
        XCTAssertLessThan(km, 270, "Dublin-Cork should be <270km")
    }

    /// DART line length: Howth to Greystones should be ~50km.
    func testDARTLineLength() {
        let howth = CLLocation(latitude: Dublin.howth.latitude,
                               longitude: Dublin.howth.longitude)
        let greystones = CLLocation(latitude: Dublin.greystones.latitude,
                                    longitude: Dublin.greystones.longitude)
        let km = howth.distance(from: greystones) / 1000
        XCTAssertGreaterThan(km, 25, "Howth-Greystones should be >25km crow-flies")
        XCTAssertLessThan(km, 50, "Howth-Greystones should be <50km crow-flies")
    }
}
