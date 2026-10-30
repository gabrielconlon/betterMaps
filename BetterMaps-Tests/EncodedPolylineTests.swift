import XCTest
import CoreLocation
@testable import CustomMapApp

/// Deterministic generator so a failing round-trip reproduces.
private struct PolylineSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class EncodedPolylineTests: XCTestCase {

    func testGoogleReferenceExample() {
        let decoded = EncodedPolyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        XCTAssertEqual(decoded.count, 3)
        let expected = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
        for (point, (lat, lon)) in zip(decoded, expected) {
            XCTAssertEqual(point.latitude, lat, accuracy: 1e-5)
            XCTAssertEqual(point.longitude, lon, accuracy: 1e-5)
        }
        let coords = expected.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        XCTAssertEqual(EncodedPolyline.encode(coords, precision: 5), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    }

    func testRoundTripDublinCoordinates() {
        var rng = PolylineSeededGenerator(seed: 0xB3773_12)
        for precision in [6, 7] {
            let tolerance = 0.5 * pow(10, -Double(precision)) * 1.01
            let coords = (0..<300).map { _ in
                CLLocationCoordinate2D(latitude: Double.random(in: 53.20...53.45, using: &rng),
                                       longitude: Double.random(in: -6.45 ... -6.05, using: &rng))
            }
            let encoded = EncodedPolyline.encode(coords, precision: precision)
            let decoded = EncodedPolyline.decode(encoded, precision: precision)
            XCTAssertEqual(decoded.count, coords.count, "precision \(precision)")
            for (a, b) in zip(coords, decoded) {
                XCTAssertEqual(a.latitude, b.latitude, accuracy: tolerance, "precision \(precision)")
                XCTAssertEqual(a.longitude, b.longitude, accuracy: tolerance, "precision \(precision)")
            }
        }
    }

    func testEmptyInputs() {
        XCTAssertEqual(EncodedPolyline.decode("", precision: 6).count, 0)
        XCTAssertEqual(EncodedPolyline.encode([], precision: 6), "")
    }

    private func assertFixtureGeometry(_ fixture: MotisFixture, precision: Int,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let response = try fixture.response()
        var legs = 0
        for (i, itinerary) in response.itineraries.enumerated() {
            for (j, leg) in itinerary.legs.enumerated() {
                legs += 1
                let label = "\(fixture.rawValue) itinerary \(i) leg \(j) \(leg.mode)"
                XCTAssertEqual(leg.legGeometry.precision, precision, label, file: file, line: line)
                let points = EncodedPolyline.decode(leg.legGeometry.points, precision: leg.legGeometry.precision)
                XCTAssertEqual(points.count, leg.legGeometry.length, label, file: file, line: line)
                let first = try XCTUnwrap(points.first, label, file: file, line: line)
                let last = try XCTUnwrap(points.last, label, file: file, line: line)
                XCTAssertEqual(first.latitude, leg.from.lat, accuracy: 1e-3, label, file: file, line: line)
                XCTAssertEqual(first.longitude, leg.from.lon, accuracy: 1e-3, label, file: file, line: line)
                XCTAssertEqual(last.latitude, leg.to.lat, accuracy: 1e-3, label, file: file, line: line)
                XCTAssertEqual(last.longitude, leg.to.lon, accuracy: 1e-3, label, file: file, line: line)
                for p in points {
                    XCTAssertTrue((53.0...53.6).contains(p.latitude) && (-6.7 ... -5.9).contains(p.longitude),
                                  "\(label): point outside Dublin \(p)", file: file, line: line)
                }
            }
        }
        XCTAssertGreaterThan(legs, 0, fixture.rawValue, file: file, line: line)
    }

    func testHeustonFixtureGeometryAtPrecision7() throws {
        try assertFixtureGeometry(.heuston, precision: 7)
    }

    func testDefaultFixtureGeometryAtPrecision6() throws {
        try assertFixtureGeometry(.default, precision: 6)
    }

    func testMappedLegCoordinatesHonourPrecision() throws {
        let response = try MotisFixture.heuston.response()
        let leg = try XCTUnwrap(MotisMapper.leg(response.itineraries[0].legs[1]))
        XCTAssertEqual(leg.coordinates.count, 207)
        XCTAssertEqual(leg.coordinates.first?.latitude ?? 0, 53.346684, accuracy: 1e-3)
        XCTAssertEqual(leg.coordinates.last?.longitude ?? 0, -6.251536, accuracy: 1e-3)
    }

    func testMalformedInputDoesNotCrash() {
        // No terminating chunk: nothing complete, nothing returned.
        XCTAssertEqual(EncodedPolyline.decode("abc", precision: 6).count, 0)
        // Bytes below the printable base (63) are invalid.
        XCTAssertEqual(EncodedPolyline.decode("!!!", precision: 6).count, 0)
        // A long run of continuation chunks would overflow a naive shift.
        XCTAssertEqual(EncodedPolyline.decode(String(repeating: "~", count: 200), precision: 6).count, 0)
        // Truncated after the first point: the first point survives.
        let truncated = EncodedPolyline.decode("_p~iF~ps|U_ul", precision: 5)
        XCTAssertEqual(truncated.count, 1)
        XCTAssertEqual(truncated.first?.latitude ?? 0, 38.5, accuracy: 1e-5)
        // A latitude with no longitude is dropped.
        XCTAssertEqual(EncodedPolyline.decode("_p~iF", precision: 5).count, 0)
        // Non-ASCII garbage.
        XCTAssertNoThrow(EncodedPolyline.decode("héllo wörld 🚆", precision: 6))
    }
}
