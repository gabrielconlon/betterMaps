import XCTest
import CoreLocation
@testable import CustomMapApp

/// Records provider calls and tracks how many are in flight at once.
private actor CallLog {
    private(set) var calls: [String] = []
    private(set) var active = 0
    private(set) var peakActive = 0

    func begin(_ key: String) {
        calls.append(key)
        active += 1
        peakActive = max(peakActive, active)
    }

    func end() { active -= 1 }
}

private struct MockProvider: DirectionsProviding {
    let log: CallLog
    /// Cache keys (see `TrailSnapService.cacheKey`) whose requests throw.
    var failingKeys: Set<String> = []
    var delayNanos: UInt64 = 0

    struct Failure: Error {}

    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        let key = TrailSnapService.cacheKey(from, to)
        await log.begin(key)
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if failingKeys.contains(key) {
            await log.end()
            throw Failure()
        }
        // A "road" route: detour through a point offset from the midpoint.
        let mid = CLLocationCoordinate2D(latitude: (from.latitude + to.latitude) / 2 + 0.0005,
                                         longitude: (from.longitude + to.longitude) / 2)
        await log.end()
        return [from, mid, to]
    }
}

final class TrailSnapServiceTests: XCTestCase {

    private let points = [TestCoords.a, TestCoords.b, TestCoords.c, TestCoords.d].map { TrailPoint(coordinate: $0) }

    func testFailingPairFallsBackToStraightSegmentOthersSnapped() async {
        let log = CallLog()
        let failing = TrailSnapService.cacheKey(TestCoords.b, TestCoords.c)   // pair index 1
        let service = TrailSnapService(provider: MockProvider(log: log, failingKeys: [failing]), maxConcurrent: 3)

        let geometry = await service.snap(points: points)

        XCTAssertEqual(geometry.segments.count, 3)
        XCTAssertEqual(geometry.segments.map(\.snapped), [true, false, true])
        XCTAssertEqual(geometry.segments[1].coords.count, 2, "straight fallback is just the two endpoints")
        XCTAssertEqual(geometry.segments[1].coords[0][0], TestCoords.b.latitude)
        XCTAssertEqual(geometry.segments[1].coords[1][0], TestCoords.c.latitude)
        XCTAssertEqual(geometry.segments[0].coords.count, 3)
        XCTAssertEqual(geometry.segments[2].coords.count, 3)
        let count = await log.calls.count
        XCTAssertEqual(count, 3)
        let cached = await service.cachedPairCount
        XCTAssertEqual(cached, 2, "failures are not cached")
    }

    func testOrderPreservedRegardlessOfCompletionOrder() async {
        let log = CallLog()
        // Small delay so completion order is unrelated to submission order.
        let service = TrailSnapService(provider: MockProvider(log: log, delayNanos: 2_000_000), maxConcurrent: 4)
        let many = [TestCoords.a, TestCoords.b, TestCoords.c, TestCoords.d, TestCoords.e, TestCoords.f, TestCoords.g]
            .map { TrailPoint(coordinate: $0) }

        let geometry = await service.snap(points: many)

        XCTAssertEqual(geometry.segments.count, many.count - 1)
        for (i, seg) in geometry.segments.enumerated() {
            XCTAssertTrue(seg.snapped)
            XCTAssertEqual(seg.coords.first?[0], many[i].latitude, "segment \(i) starts at point \(i)")
            XCTAssertEqual(seg.coords.last?[0], many[i + 1].latitude, "segment \(i) ends at point \(i + 1)")
        }
    }

    func testCacheHitAvoidsSecondProviderCall() async {
        let log = CallLog()
        let service = TrailSnapService(provider: MockProvider(log: log))

        let first = await service.snap(points: points)
        var count = await log.calls.count
        XCTAssertEqual(count, 3)

        let second = await service.snap(points: points)
        count = await log.calls.count
        XCTAssertEqual(count, 3, "every pair was cached; no new provider calls")
        XCTAssertEqual(first, second)

        // Sub-meter nudge (1e-7 degrees) still hits the 5 dp cache key.
        var nudged = points
        nudged[0].latitude += 0.000_000_1
        _ = await service.snap(points: nudged)
        count = await log.calls.count
        XCTAssertEqual(count, 3)

        // Moving a point for real only refetches the segments that touch it.
        var moved = points
        moved[1] = TrailPoint(coordinate: CLLocationCoordinate2D(latitude: 53.3420, longitude: -6.2520))
        _ = await service.snap(points: moved)
        count = await log.calls.count
        XCTAssertEqual(count, 5, "pairs 0 and 1 refetched, pair 2 cached")
    }

    func testConcurrencyIsBounded() async {
        let log = CallLog()
        let service = TrailSnapService(provider: MockProvider(log: log, delayNanos: 5_000_000), maxConcurrent: 2)
        let many = [TestCoords.a, TestCoords.b, TestCoords.c, TestCoords.d, TestCoords.e, TestCoords.f, TestCoords.g]
            .map { TrailPoint(coordinate: $0) }

        let geometry = await service.snap(points: many)

        XCTAssertEqual(geometry.segments.count, 6)
        let peak = await log.peakActive
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertGreaterThanOrEqual(peak, 1)
    }

    func testTooFewPointsYieldsEmptyGeometryWithoutProviderCalls() async {
        let log = CallLog()
        let service = TrailSnapService(provider: MockProvider(log: log))
        let one = await service.snap(points: [points[0]])
        let none = await service.snap(points: [])
        XCTAssertTrue(one.isEmpty)
        XCTAssertTrue(none.isEmpty)
        let count = await log.calls.count
        XCTAssertEqual(count, 0)
    }

    func testStraightMatchesTrailGeometryStraight() {
        let service = TrailSnapService(provider: MockProvider(log: CallLog()))
        let straight = service.straight(points: points)
        XCTAssertEqual(straight, TrailGeometry.straight(through: points.map(\.coordinate)))
        XCTAssertEqual(straight.segments.count, 3)
        XCTAssertTrue(straight.segments.allSatisfy { !$0.snapped })
    }

    func testCacheKeyRoundsToFiveDecimals() {
        let a = CLLocationCoordinate2D(latitude: 53.123456789, longitude: -6.987654321)
        let b = CLLocationCoordinate2D(latitude: 53.2, longitude: -6.3)
        XCTAssertEqual(TrailSnapService.cacheKey(a, b), "53.12346,-6.98765|53.20000,-6.30000")
        XCTAssertNotEqual(TrailSnapService.cacheKey(a, b), TrailSnapService.cacheKey(b, a), "direction matters")
    }
}
