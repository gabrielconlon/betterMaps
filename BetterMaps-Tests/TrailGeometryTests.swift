import XCTest
import SwiftData
import CoreLocation
@testable import CustomMapApp

final class TrailGeometryTests: XCTestCase {

    private var sample: TrailGeometry {
        TrailGeometry(segments: [
            .init(coordinates: [TestCoords.a, TestCoords.b], snapped: false),
            .init(coordinates: [TestCoords.b,
                                CLLocationCoordinate2D(latitude: 53.3450, longitude: -6.2505),
                                TestCoords.c], snapped: true),
        ])
    }

    func testRoundTripEncodeDecode() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(TrailGeometry.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.segments[1].coords.count, 3)
        XCTAssertTrue(decoded.segments[1].snapped)
    }

    func testTotalMetersIsHaversineSumOverEveryVertex() {
        let g = sample
        let mid = g.segments[1].coordinates[1]
        let expected = WaypointGraph.meters(TestCoords.a, TestCoords.b)
            + WaypointGraph.meters(TestCoords.b, mid)
            + WaypointGraph.meters(mid, TestCoords.c)
        XCTAssertEqual(g.totalMeters, expected, accuracy: 0.001)
        XCTAssertEqual(TrailGeometry().totalMeters, 0)
        XCTAssertTrue(TrailGeometry().isEmpty)
    }

    func testMalformedCoordinatePairsAreSkipped() {
        let seg = TrailGeometry.Segment(coords: [[53.34, -6.26], [1.0], [], [53.34, -6.25, 99]], snapped: false)
        XCTAssertEqual(seg.coordinates.count, 2)
        XCTAssertEqual(seg.meters, WaypointGraph.meters(TestCoords.a, TestCoords.b), accuracy: 0.001)
    }

    func testStraightThroughBuildsOneSegmentPerPair() {
        let g = TrailGeometry.straight(through: [TestCoords.a, TestCoords.b, TestCoords.c])
        XCTAssertEqual(g.segments.count, 2)
        XCTAssertTrue(g.segments.allSatisfy { !$0.snapped && $0.coords.count == 2 })
        XCTAssertTrue(TrailGeometry.straight(through: [TestCoords.a]).isEmpty)
    }

    @MainActor
    func testTrailGeometryAccessorPersistsThroughData() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let trail = Trail(name: "Round trip")
        context.insert(trail)
        XCTAssertNil(trail.geometry)

        trail.geometry = sample
        XCTAssertNotNil(trail.geometryData)
        XCTAssertEqual(trail.geometry, sample)

        trail.geometryData = Data("not json".utf8)
        XCTAssertNil(trail.geometry, "malformed blob reads as nil, never crashes")

        trail.geometry = nil
        XCTAssertNil(trail.geometryData)
    }

    @MainActor
    func testLayerTrailsRelationshipRoundTrips() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let layer = Layer(name: "Trails", kind: .waypointPath)
        context.insert(layer)
        let trail = Trail(name: "T1")
        context.insert(trail)
        layer.trails?.append(trail)

        XCTAssertEqual(trail.layer?.id, layer.id)
        XCTAssertEqual(layer.trails?.count, 1)
    }
}
