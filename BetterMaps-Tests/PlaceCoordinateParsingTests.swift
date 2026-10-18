import XCTest
import CoreLocation
@testable import CustomMapApp

final class PlaceCoordinateParsingTests: XCTestCase {

    private func assertParses(_ text: String, _ lat: Double, _ lng: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let c = CoordinateText.parse(text) else {
            return XCTFail("Expected \"\(text)\" to parse", file: file, line: line)
        }
        XCTAssertEqual(c.latitude, lat, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(c.longitude, lng, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: parse

    func testCommaSeparatedPair() {
        assertParses("53.3498, -6.2603", 53.3498, -6.2603)
    }

    func testWhitespaceSemicolonAndBracketSeparated() {
        assertParses("53.3498 -6.2603", 53.3498, -6.2603)
        assertParses("53.3498;-6.2603", 53.3498, -6.2603)
        assertParses("  (53.3498, -6.2603)\n", 53.3498, -6.2603)
    }

    func testUnicodeMinusAndDegrees() {
        assertParses("53.3498°, \u{2212}6.2603°", 53.3498, -6.2603)
    }

    func testHemisphereSuffixes() {
        assertParses("53.3498° N, 6.2603° W", 53.3498, -6.2603)
        assertParses("33.8688S 151.2093E", -33.8688, 151.2093)
        assertParses("53.3498n, 6.2603w", 53.3498, -6.2603)
    }

    func testRejectsGarbageAndWrongArity() {
        XCTAssertNil(CoordinateText.parse(""))
        XCTAssertNil(CoordinateText.parse("Dublin"))
        XCTAssertNil(CoordinateText.parse("53.3498"))
        XCTAssertNil(CoordinateText.parse("53.3498, -6.2603, 10"))
    }

    func testRejectsOutOfRange() {
        XCTAssertNil(CoordinateText.parse("91, 0"))
        XCTAssertNil(CoordinateText.parse("0, 181"))
    }

    func testRejectsContradictorySignAndHemisphere() {
        XCTAssertNil(CoordinateText.parse("53.3498, -6.2603 W"))
    }

    // MARK: validated

    func testValidatedRequiresBothValues() {
        XCTAssertNil(CoordinateText.validated(latitude: nil, longitude: 1))
        XCTAssertNil(CoordinateText.validated(latitude: 1, longitude: nil))
        XCTAssertNotNil(CoordinateText.validated(latitude: 0, longitude: 0))
    }

    func testValidatedBounds() {
        XCTAssertNotNil(CoordinateText.validated(latitude: 90, longitude: 180))
        XCTAssertNotNil(CoordinateText.validated(latitude: -90, longitude: -180))
        XCTAssertNil(CoordinateText.validated(latitude: 90.0001, longitude: 0))
        XCTAssertNil(CoordinateText.validated(latitude: 0, longitude: -180.0001))
        XCTAssertNil(CoordinateText.validated(latitude: .nan, longitude: 0))
        XCTAssertNil(CoordinateText.validated(latitude: 0, longitude: .infinity))
    }

    func testParseComponent() {
        XCTAssertEqual(CoordinateText.parseComponent("-6.26"), -6.26)
        XCTAssertEqual(CoordinateText.parseComponent("\u{2212}6.26"), -6.26)
        XCTAssertEqual(CoordinateText.parseComponent("6.26° W"), -6.26)
        XCTAssertNil(CoordinateText.parseComponent("W"))
        XCTAssertNil(CoordinateText.parseComponent("abc"))
    }
}
