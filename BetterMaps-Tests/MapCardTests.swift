import XCTest
import CoreLocation
@testable import CustomMapApp

/// Which router sheets the Mac lets a map click or Escape close. Forms must
/// never be in this set: closing one throws away what was typed.
final class MapCardTests: XCTestCase {

    func testCardsAboutThingsOnTheMapAreMapCards() {
        let stop = TransitStop(id: "x", name: "x", latitude: 53, longitude: -6, kind: .bus)
        let coordinate = CLLocationCoordinate2D(latitude: 53, longitude: -6)
        XCTAssertTrue(ActiveSheet.transitArrivals(stop).isMapCard)
        XCTAssertTrue(ActiveSheet.poiLookup(coordinate).isMapCard)
        XCTAssertTrue(ActiveSheet.trailDetail(UUID()).isMapCard)
    }

    func testFormsAndManagementScreensAreNot() {
        let coordinate = CLLocationCoordinate2D(latitude: 53, longitude: -6)
        XCTAssertFalse(ActiveSheet.newPlace(coordinate).isMapCard)
        XCTAssertFalse(ActiveSheet.quickAdd(coordinate).isMapCard)
        XCTAssertFalse(ActiveSheet.newLayer(.places).isMapCard)
        XCTAssertFalse(ActiveSheet.editLayer(UUID()).isMapCard)
        XCTAssertFalse(ActiveSheet.layerDetail(UUID()).isMapCard)
        XCTAssertFalse(ActiveSheet.settings.isMapCard)
    }
}
