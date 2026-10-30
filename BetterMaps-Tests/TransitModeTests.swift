import XCTest
@testable import CustomMapApp

final class TransitModeTests: XCTestCase {
    func testEveryLayerKindBridgesToAModeAndBack() {
        for kind in TransitLayerKind.allCases {
            let mode = TransitMode(kind)
            XCTAssertEqual(mode.layerKind, kind)
            XCTAssertEqual(mode.rawValue, kind.rawValue)
            XCTAssertTrue(mode.isTransit)
        }
    }

    func testWalkAndBikeHaveNoLayer() {
        XCTAssertNil(TransitMode.walk.layerKind)
        XCTAssertNil(TransitMode.bike.layerKind)
        XCTAssertFalse(TransitMode.walk.isTransit)
        XCTAssertFalse(TransitMode.bike.isTransit)
    }

    func testDisplayNamesAndImages() {
        XCTAssertEqual(TransitMode.bus.displayName, TransitLayerKind.bus.displayName)
        XCTAssertEqual(TransitMode.dart.displayName, "DART")
        XCTAssertEqual(TransitMode.walk.displayName, "Walk")
        XCTAssertEqual(TransitMode.bike.displayName, "Bike")
        XCTAssertEqual(TransitMode.luas.systemImage, TransitLayerKind.luas.systemImage)
        XCTAssertEqual(TransitMode.walk.systemImage, "figure.walk")
        XCTAssertEqual(TransitMode.bike.systemImage, "bicycle")
    }

    func testTransitModesComeFirstInAllCases() {
        XCTAssertEqual(TransitMode.allCases.filter(\.isTransit).count, TransitLayerKind.allCases.count)
        XCTAssertEqual(TransitMode.allCases.map(\.id), ["bus", "luas", "dart", "rail", "walk", "bike"])
    }
}
