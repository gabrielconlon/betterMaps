import XCTest
import CoreLocation
import SwiftData
@testable import CustomMapApp

final class TrailDraftTests: XCTestCase {

    // MARK: - add

    func testAddAppendsAndFlagsFirstPointAsEndpoint() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        draft.add(TestCoords.c)

        XCTAssertEqual(draft.points.count, 3)
        XCTAssertEqual(draft.points.map(\.isEndpoint), [true, false, false])
        XCTAssertEqual(draft.points.map(\.latitude), [TestCoords.a.latitude, TestCoords.b.latitude, TestCoords.c.latitude])
        XCTAssertEqual(draft.undoStack.count, 3, "one undo step per add")
    }

    func testAddWithin30mOfSegmentInsertsAtThatIndex() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        draft.add(TestCoords.c)   // b -> c runs north along lon -6.25

        // Midpoint of b–c, nudged ~10 m east (0.00015° lon at 53.3°N ≈ 10 m).
        let nearBC = CLLocationCoordinate2D(latitude: 53.3450, longitude: -6.2500 + 0.00015)
        draft.add(nearBC)

        XCTAssertEqual(draft.points.count, 4)
        XCTAssertEqual(draft.points[2].latitude, nearBC.latitude, "inserted between b (1) and c (2)")
        XCTAssertEqual(draft.points[3].latitude, TestCoords.c.latitude)
        XCTAssertFalse(draft.points[2].isEndpoint)
    }

    func testAddFarFromAnySegmentAppends() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        // ~110 m north of the a–b segment's midpoint.
        let far = CLLocationCoordinate2D(latitude: 53.3410, longitude: -6.2550)
        draft.add(far)
        XCTAssertEqual(draft.points.last?.latitude, far.latitude)
    }

    func testTapJustPastTheEndAppends() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)   // a -> b runs east along lat 53.34
        // ~10 m east of b, in line with a–b: within 30 m of the segment, but
        // its projection falls past b, so it extends the trail.
        let pastB = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2500 + 0.00015)
        draft.add(pastB)
        XCTAssertEqual(draft.points.count, 3)
        XCTAssertEqual(draft.points.last?.longitude, pastB.longitude, "appended after b, not inserted before it")
        XCTAssertEqual(draft.points[1].longitude, TestCoords.b.longitude)

        // Same before the start: appended too (only interior taps insert).
        let beforeA = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2600 - 0.00015)
        XCTAssertNil(TrailDraft.nearestSegmentInsertionIndex(points: draft.points, coordinate: beforeA))
    }

    func testProjectionParameterIsUnclamped() {
        let mid = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2550)
        let past = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2400)
        XCTAssertEqual(TrailDraft.projection(of: mid, ontoSegment: TestCoords.a, TestCoords.b).t, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(TrailDraft.projection(of: past, ontoSegment: TestCoords.a, TestCoords.b).t, 1)
    }

    func testFreshPointIdsKeepsCoordinatesAndFlags() {
        var draft = TrailDraft(name: "Canal")
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        let fresh = draft.withFreshPointIds()
        XCTAssertEqual(fresh.points.count, 2)
        XCTAssertTrue(Set(fresh.points.map(\.id)).isDisjoint(with: Set(draft.points.map(\.id))))
        XCTAssertEqual(fresh.points.map(\.latitude), draft.points.map(\.latitude))
        XCTAssertEqual(fresh.points.map(\.isEndpoint), draft.points.map(\.isEndpoint))
        XCTAssertEqual(fresh.name, "Canal")
    }

    func testNearestSegmentInsertionIndexThresholdAndEmptyCases() {
        let pts = [TrailPoint(coordinate: TestCoords.a), TrailPoint(coordinate: TestCoords.b)]
        let onLine = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2550)
        XCTAssertEqual(TrailDraft.nearestSegmentInsertionIndex(points: pts, coordinate: onLine), 1)

        let offBy50m = CLLocationCoordinate2D(latitude: 53.3400 + 50.0 / 111_320.0, longitude: -6.2550)
        XCTAssertNil(TrailDraft.nearestSegmentInsertionIndex(points: pts, coordinate: offBy50m))
        XCTAssertEqual(TrailDraft.nearestSegmentInsertionIndex(points: pts, coordinate: offBy50m, maxMeters: 60), 1)

        XCTAssertNil(TrailDraft.nearestSegmentInsertionIndex(points: [pts[0]], coordinate: onLine))
        XCTAssertNil(TrailDraft.nearestSegmentInsertionIndex(points: [], coordinate: onLine))
    }

    func testDistanceToSegmentClampsToEndpoints() {
        // Point beyond b along the a→b line: distance should be to b, not the infinite line.
        let beyond = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2400)
        let d = TrailDraft.distance(from: beyond, toSegment: TestCoords.a, TestCoords.b)
        XCTAssertEqual(d, WaypointGraph.meters(beyond, TestCoords.b), accuracy: 2.0)

        // Degenerate segment (a == a) falls back to point distance.
        XCTAssertEqual(TrailDraft.distance(from: TestCoords.b, toSegment: TestCoords.a, TestCoords.a),
                       WaypointGraph.meters(TestCoords.a, TestCoords.b), accuracy: 2.0)
    }

    // MARK: - remove / toggle / move / undo

    func testRemoveThenUndoRestores() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        let before = draft.points
        let removedId = draft.points[1].id

        draft.remove(removedId)
        XCTAssertEqual(draft.points.count, 1)
        XCTAssertTrue(draft.canUndo)

        XCTAssertTrue(draft.undo())
        XCTAssertEqual(draft.points, before)
    }

    func testRemoveUnknownIdDoesNotPushUndo() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        let depth = draft.undoStack.count
        draft.remove(UUID())
        XCTAssertEqual(draft.undoStack.count, depth)
    }

    func testToggleEndpointIsUndoable() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        let id = draft.points[1].id
        draft.toggleEndpoint(id)
        XCTAssertTrue(draft.points[1].isEndpoint)
        draft.undo()
        XCTAssertFalse(draft.points[1].isEndpoint)
    }

    func testDragIsOneUndoStep() {
        var draft = TrailDraft()
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        let id = draft.points[1].id
        let depth = draft.undoStack.count

        draft.beginMove()
        draft.move(id, to: TestCoords.c)
        draft.move(id, to: TestCoords.d)
        draft.move(id, to: TestCoords.e)
        draft.endMove()

        XCTAssertEqual(draft.undoStack.count, depth + 1)
        XCTAssertEqual(draft.points[1].latitude, TestCoords.e.latitude)
        draft.undo()
        XCTAssertEqual(draft.points[1].latitude, TestCoords.b.latitude)
    }

    func testUndoOnEmptyStackReturnsFalse() {
        var draft = TrailDraft()
        XCTAssertFalse(draft.canUndo)
        XCTAssertFalse(draft.undo())
    }

    func testUndoStackCappedAtFifty() {
        var draft = TrailDraft()
        for i in 0..<70 {
            draft.add(CLLocationCoordinate2D(latitude: 53.0 + Double(i) * 0.01, longitude: -6.0))
        }
        XCTAssertEqual(draft.undoStack.count, TrailDraft.undoLimit)
        XCTAssertEqual(TrailDraft.undoLimit, 50)

        var undone = 0
        while draft.undo() { undone += 1 }
        XCTAssertEqual(undone, 50)
        XCTAssertEqual(draft.points.count, 20, "the 20 oldest adds are no longer undoable")
    }

    // MARK: - straightMeters

    func testStraightMetersMatchesHaversineSum() {
        var draft = TrailDraft()
        XCTAssertEqual(draft.straightMeters, 0)
        draft.add(TestCoords.a)
        XCTAssertEqual(draft.straightMeters, 0)
        draft.add(TestCoords.b)
        draft.add(TestCoords.c)
        let expected = WaypointGraph.meters(TestCoords.a, TestCoords.b) + WaypointGraph.meters(TestCoords.b, TestCoords.c)
        XCTAssertEqual(draft.straightMeters, expected, accuracy: 0.001)
        XCTAssertGreaterThan(expected, 1500)
    }

    // MARK: - init(trail:places:)

    @MainActor
    func testInitFromTrailOrdersBySortIndexThenCreatedAt() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let pathId = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let t2 = Date(timeIntervalSince1970: 3_000)

        // Legacy data: sortIndex all 0 → createdAt decides. One point has
        // sortIndex 1 and must go last despite being created first.
        let late = Place(name: "late", latitude: 1, longitude: 1)
        late.pathId = pathId; late.sortIndex = 1; late.createdAt = t0; late.isWaypointEndpoint = true
        let second = Place(name: "second", latitude: 2, longitude: 2)
        second.pathId = pathId; second.sortIndex = 0; second.createdAt = t2
        let first = Place(name: "first", latitude: 3, longitude: 3)
        first.pathId = pathId; first.sortIndex = 0; first.createdAt = t1; first.isWaypointEndpoint = true
        let other = Place(name: "other path", latitude: 4, longitude: 4)
        other.pathId = UUID(); other.sortIndex = 0; other.createdAt = t0

        for p in [late, second, first, other] { context.insert(p) }

        let trail = Trail(pathId: pathId, name: "Canal", isSnapped: true)
        context.insert(trail)

        let draft = TrailDraft(trail: trail, places: [late, second, first, other])
        XCTAssertEqual(draft.points.map(\.id), [first.id, second.id, late.id])
        XCTAssertEqual(draft.points.map(\.isEndpoint), [true, false, true])
        XCTAssertEqual(draft.name, "Canal")
        XCTAssertTrue(draft.isSnapped)
        XCTAssertFalse(draft.canUndo)
    }
}
