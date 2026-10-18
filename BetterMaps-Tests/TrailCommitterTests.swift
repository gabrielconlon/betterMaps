import XCTest
import SwiftData
import CoreLocation
@testable import CustomMapApp

@MainActor
final class TrailCommitterTests: XCTestCase {

    private func draft(_ coords: [CLLocationCoordinate2D], name: String = "Canal") -> TrailDraft {
        var d = TrailDraft(name: name)
        for c in coords { d.points.append(TrailPoint(coordinate: c)) }
        d.points[0].isEndpoint = true
        return d
    }

    private func places(on trail: Trail, in layer: Layer) -> [Place] {
        (layer.places ?? []).filter { $0.pathId == trail.pathId }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func testCommitNewTrailCreatesPlacesAndTrail() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)

        let d = draft([TestCoords.a, TestCoords.b, TestCoords.c])
        let trail = TrailCommitter.commit(d, geometry: nil, to: layer, trail: nil, in: context)

        let members = places(on: trail, in: layer)
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(members.map(\.sortIndex), [0, 1, 2])
        XCTAssertEqual(members.map(\.id), d.points.map(\.id), "place ids mirror point ids")
        XCTAssertEqual(members.map(\.isWaypointEndpoint), [true, false, false])
        XCTAssertTrue(members.allSatisfy { $0.name == "Waypoint" })
        XCTAssertEqual(trail.name, "Canal")
        XCTAssertEqual(trail.distanceMeters, d.straightMeters, accuracy: 0.001)
        XCTAssertGreaterThan(trail.distanceMeters, 0)
        XCTAssertEqual(layer.trails?.map(\.id), [trail.id])
        XCTAssertEqual(layer.pathNames[trail.pathId], "Canal")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Place>()).count, 3)
    }

    func testGeometryDrivesDistanceAndSnapFlag() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)

        var d = draft([TestCoords.a, TestCoords.b])
        d.isSnapped = true
        let detour = TrailGeometry(segments: [
            .init(coordinates: [TestCoords.a, TestCoords.c, TestCoords.b], snapped: true)
        ])
        let trail = TrailCommitter.commit(d, geometry: detour, to: layer, trail: nil, in: context)
        XCTAssertTrue(trail.isSnapped)
        XCTAssertEqual(trail.geometry, detour)
        XCTAssertEqual(trail.distanceMeters, detour.totalMeters, accuracy: 0.001)
        XCTAssertGreaterThan(trail.distanceMeters, d.straightMeters)
    }

    func testRecommitAfterRemovingPointDeletesThatPlace() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)

        let first = draft([TestCoords.a, TestCoords.b, TestCoords.c])
        let trail = TrailCommitter.commit(first, geometry: nil, to: layer, trail: nil, in: context)
        places(on: trail, in: layer)[0].name = "Lock 1"

        var edit = TrailDraft(trail: trail, places: layer.places ?? [])
        let removedId = edit.points[1].id
        edit.remove(removedId)
        edit.name = "Canal walk"
        let same = TrailCommitter.commit(edit, geometry: nil, to: layer, trail: trail, in: context)

        XCTAssertEqual(same.id, trail.id)
        let members = places(on: trail, in: layer)
        XCTAssertEqual(members.count, 2)
        XCTAssertFalse(members.contains { $0.id == removedId })
        XCTAssertEqual(members.map(\.sortIndex), [0, 1])
        XCTAssertEqual(members[0].name, "Lock 1", "existing names are kept")
        XCTAssertEqual(same.name, "Canal walk")
        XCTAssertEqual(same.distanceMeters, edit.straightMeters, accuracy: 0.001)
        XCTAssertEqual(layer.pathNames[trail.pathId], "Canal walk")

        let all = try context.fetch(FetchDescriptor<Place>())
        XCTAssertEqual(all.count, 2)
        XCTAssertFalse(all.contains { $0.id == removedId })
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 1)
    }

    func testDeleteRemovesPlacesAndTrailButNotOtherTrails() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)

        let doomed = TrailCommitter.commit(draft([TestCoords.a, TestCoords.b, TestCoords.c]),
                                           geometry: nil, to: layer, trail: nil, in: context)
        let survivor = TrailCommitter.commit(draft([TestCoords.e, TestCoords.f], name: "Park"),
                                             geometry: nil, to: layer, trail: nil, in: context)
        let doomedPathId = doomed.pathId

        TrailCommitter.delete(doomed, in: context)

        let placesLeft = try context.fetch(FetchDescriptor<Place>())
        XCTAssertEqual(placesLeft.count, 2)
        XCTAssertFalse(placesLeft.contains { $0.pathId == doomedPathId })
        let trailsLeft = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trailsLeft.map(\.id), [survivor.id])
        XCTAssertEqual(layer.trails?.map(\.id), [survivor.id])
        XCTAssertNil(layer.pathNames[doomedPathId])
        XCTAssertEqual(layer.pathNames[survivor.pathId], "Park")
    }

    func testBlankNameFallsBackToTrailN() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)

        let t1 = TrailCommitter.commit(draft([TestCoords.a, TestCoords.b], name: "  "),
                                       geometry: nil, to: layer, trail: nil, in: context)
        let t2 = TrailCommitter.commit(draft([TestCoords.c, TestCoords.d], name: ""),
                                       geometry: nil, to: layer, trail: nil, in: context)
        XCTAssertEqual(t1.name, "Trail 1")
        XCTAssertEqual(t2.name, "Trail 2")
    }
}
