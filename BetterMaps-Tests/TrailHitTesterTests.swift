import XCTest
import CoreGraphics
@testable import CustomMapApp

final class TrailHitTesterTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testHitOnSegmentMidpoint() {
        let trails = [(id: a, screenPoints: [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]])]
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 50, y: 5), trails: trails), a)
    }

    func testMissBeyondTolerance() {
        let trails = [(id: a, screenPoints: [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]])]
        XCTAssertNil(TrailHitTester.hit(tap: CGPoint(x: 50, y: 23), trails: trails))
        // Past the end of the segment: distance is to the endpoint, not the infinite line.
        XCTAssertNil(TrailHitTester.hit(tap: CGPoint(x: 130, y: 0), trails: trails))
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 50, y: 23), trails: trails, tolerance: 30), a)
    }

    func testNearestOfTwoWins() {
        let trails = [
            (id: a, screenPoints: [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]]),
            (id: b, screenPoints: [[CGPoint(x: 0, y: 20), CGPoint(x: 100, y: 20)]]),
        ]
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 50, y: 14), trails: trails), b)
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 50, y: 6), trails: trails), a)
    }

    func testMultiSegmentPolylineUsesClosestSegment() {
        let trails = [(id: a, screenPoints: [
            [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)],
        ])]
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 110, y: 80), trails: trails), a)
    }

    func testDegenerateTrails() {
        let single = [(id: a, screenPoints: [[CGPoint(x: 10, y: 10)]])]
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 15, y: 15), trails: single), a)
        XCTAssertNil(TrailHitTester.hit(tap: CGPoint(x: 60, y: 60), trails: single))

        // Zero-length segment behaves like a point.
        let zero = [(id: a, screenPoints: [[CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)]])]
        XCTAssertEqual(TrailHitTester.hit(tap: CGPoint(x: 10, y: 20), trails: zero), a)

        let empty = [(id: a, screenPoints: [[CGPoint]]()), (id: b, screenPoints: [[CGPoint]()])]
        XCTAssertNil(TrailHitTester.hit(tap: .zero, trails: empty))
        XCTAssertNil(TrailHitTester.hit(tap: .zero, trails: []))
    }
}
