import XCTest
import SwiftData
@testable import CustomMapApp

@MainActor
final class TrailMigratorTests: XCTestCase {

    private func makePlace(_ name: String, lat: Double, lon: Double, pathId: UUID?, sortIndex: Int,
                           createdAt: Date, in context: ModelContext) -> Place {
        let p = Place(name: name, latitude: lat, longitude: lon)
        p.pathId = pathId
        p.sortIndex = sortIndex
        p.createdAt = createdAt
        context.insert(p)
        return p
    }

    func testCreatesOneTrailPerPathWithNamesAndIsIdempotent() throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let layer = Layer(name: "Walking Trails", kind: .waypointPath)
        context.insert(layer)

        let canalId = UUID()
        let parkId = UUID()
        layer.pathNames = [canalId: "Grand Canal", parkId: "Phoenix Park"]

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let canal = [
            makePlace("c0", lat: 53.3400, lon: -6.2600, pathId: canalId, sortIndex: 0, createdAt: t, in: context),
            makePlace("c1", lat: 53.3400, lon: -6.2500, pathId: canalId, sortIndex: 1, createdAt: t.addingTimeInterval(1), in: context),
        ]
        let park = [
            makePlace("p0", lat: 53.3500, lon: -6.2500, pathId: parkId, sortIndex: 0, createdAt: t.addingTimeInterval(100), in: context),
            makePlace("p1", lat: 53.3500, lon: -6.2400, pathId: parkId, sortIndex: 1, createdAt: t.addingTimeInterval(101), in: context),
        ]
        let legacy = [
            makePlace("l0", lat: 53.3600, lon: -6.2400, pathId: nil, sortIndex: 0, createdAt: t.addingTimeInterval(200), in: context),
            makePlace("l1", lat: 53.3600, lon: -6.2300, pathId: nil, sortIndex: 0, createdAt: t.addingTimeInterval(201), in: context),
            makePlace("l2", lat: 53.3700, lon: -6.2300, pathId: nil, sortIndex: 0, createdAt: t.addingTimeInterval(202), in: context),
        ]
        layer.places = canal + park + legacy

        // First run.
        let trails = TrailMigrator.ensureTrails(for: layer, in: context)
        XCTAssertEqual(trails.count, 3)
        XCTAssertEqual(trails.map(\.name), ["Grand Canal", "Phoenix Park", "Trail 3"], "sorted by createdAt")
        XCTAssertEqual(trails[0].pathId, canalId)
        XCTAssertEqual(trails[1].pathId, parkId)

        // Legacy places were assigned one shared, non-nil pathId that the third trail uses.
        let legacyIds = Set(legacy.compactMap(\.pathId))
        XCTAssertEqual(legacyIds.count, 1)
        XCTAssertEqual(trails[2].pathId, legacyIds.first)
        XCTAssertTrue(layer.places?.allSatisfy { $0.pathId != nil } ?? false)

        // Relationship wired both ways.
        XCTAssertEqual(Set((layer.trails ?? []).map(\.id)), Set(trails.map(\.id)))
        XCTAssertTrue(trails.allSatisfy { $0.layer?.id == layer.id })

        // Straight geometry and distance were seeded.
        let canalMeters = WaypointGraph.meters(canal[0].coordinate, canal[1].coordinate)
        XCTAssertEqual(trails[0].distanceMeters, canalMeters, accuracy: 0.01)
        XCTAssertEqual(trails[0].geometry?.segments.count, 1)
        XCTAssertEqual(trails[2].geometry?.segments.count, 2)
        XCTAssertFalse(trails[0].isSnapped)

        // Second run adds nothing and returns the same trails.
        let again = TrailMigrator.ensureTrails(for: layer, in: context)
        XCTAssertEqual(again.map(\.id), trails.map(\.id))
        let stored = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(stored.count, 3)

        // Legacy places keep the pathId assigned on the first run.
        XCTAssertEqual(Set(legacy.compactMap(\.pathId)), legacyIds)
    }

    func testEmptyLayerProducesNoTrails() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Empty", kind: .waypointPath)
        context.insert(layer)

        XCTAssertTrue(TrailMigrator.ensureTrails(for: layer, in: context).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 0)
    }

    func testPreexistingTrailIsReusedAndNewPathNumbersAfterIt() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Mixed", kind: .waypointPath)
        context.insert(layer)

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let existingPath = UUID()
        let existing = Trail(pathId: existingPath, name: "Already here", createdAt: t)
        context.insert(existing)
        existing.layer = layer

        _ = makePlace("e0", lat: 1, lon: 1, pathId: existingPath, sortIndex: 0, createdAt: t, in: context)
        let newPath = UUID()
        _ = makePlace("n0", lat: 2, lon: 2, pathId: newPath, sortIndex: 0, createdAt: t.addingTimeInterval(10), in: context)
        layer.places = try context.fetch(FetchDescriptor<Place>())

        let trails = TrailMigrator.ensureTrails(for: layer, in: context)
        XCTAssertEqual(trails.map(\.name), ["Already here", "Trail 2"])
        XCTAssertEqual(trails[0].id, existing.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 2)
    }

    // MARK: - Saved places are never waypoints

    func testNeverAssignsPathIdToPlaceAlsoInPlacesLayer() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let trails = Layer(name: "Walks", kind: .waypointPath)
        let coffee = Layer(name: "Coffee", kind: .places)
        context.insert(trails)
        context.insert(coffee)

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let shared = makePlace("Two Boys Brew", lat: 53.34, lon: -6.26, pathId: nil, sortIndex: 0,
                               createdAt: t, in: context)
        let w0 = makePlace("Waypoint", lat: 53.35, lon: -6.25, pathId: nil, sortIndex: 0,
                           createdAt: t.addingTimeInterval(1), in: context)
        let w1 = makePlace("Waypoint", lat: 53.36, lon: -6.24, pathId: nil, sortIndex: 1,
                           createdAt: t.addingTimeInterval(2), in: context)
        coffee.places = [shared]
        trails.places = [shared, w0, w1]

        let result = TrailMigrator.ensureTrails(for: trails, in: context)

        XCTAssertNil(shared.pathId, "a place in a Places layer must never become a waypoint")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(w0.pathId, result.first?.pathId)
        XCTAssertEqual(w1.pathId, result.first?.pathId)
        XCTAssertEqual(result.first?.geometry?.segments.count, 1, "only the two waypoints are on the line")

        // Deleting that trail keeps the shared place.
        TrailCommitter.delete(try XCTUnwrap(result.first), in: context)
        let left = try context.fetch(FetchDescriptor<Place>())
        XCTAssertEqual(left.map(\.id), [shared.id])
        XCTAssertEqual(coffee.places?.map(\.id), [shared.id])
    }

    func testLegacyPlaceWithUserContentIsLeftAlone() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Switched", kind: .waypointPath)
        context.insert(layer)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let rich = makePlace("Brunch spot", lat: 1, lon: 1, pathId: nil, sortIndex: 0, createdAt: t, in: context)
        rich.notes = "Great eggs"
        layer.places = [rich]

        XCTAssertTrue(TrailMigrator.ensureTrails(for: layer, in: context).isEmpty)
        XCTAssertNil(rich.pathId)
    }

    // MARK: - Multi-device safety

    func testLegacyPathIdIsDeterministicFromLayerId() throws {
        let layerId = UUID()
        let first = TrailMigrator.legacyPathId(for: layerId)
        XCTAssertEqual(first, TrailMigrator.legacyPathId(for: layerId))
        XCTAssertNotEqual(first, layerId)
        XCTAssertNotEqual(first, TrailMigrator.legacyPathId(for: UUID()))

        // Two "devices" (separate stores) migrating the same layer agree.
        func migrate() throws -> UUID? {
            let container = try makeTestContainer()
            let context = container.mainContext
            let layer = Layer(name: "Walks", kind: .waypointPath)
            layer.id = layerId
            context.insert(layer)
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            layer.places = [
                makePlace("Waypoint", lat: 1, lon: 1, pathId: nil, sortIndex: 0, createdAt: t, in: context),
                makePlace("Waypoint", lat: 2, lon: 2, pathId: nil, sortIndex: 1, createdAt: t, in: context),
            ]
            return TrailMigrator.ensureTrails(for: layer, in: context).first?.pathId
        }
        let deviceA = try migrate()
        let deviceB = try migrate()
        XCTAssertEqual(deviceA, first)
        XCTAssertEqual(deviceB, first)
    }

    func testDuplicateTrailsForSamePathCollapseToSnappedOne() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let pid = UUID()
        layer.places = [
            makePlace("Waypoint", lat: 1, lon: 1, pathId: pid, sortIndex: 0, createdAt: t, in: context),
            makePlace("Waypoint", lat: 2, lon: 2, pathId: pid, sortIndex: 1, createdAt: t, in: context),
        ]
        let older = Trail(pathId: pid, name: "Older", createdAt: t)
        let snapped = Trail(pathId: pid, name: "Snapped", isSnapped: true, createdAt: t.addingTimeInterval(60))
        let newer = Trail(pathId: pid, name: "Newer", createdAt: t.addingTimeInterval(120))
        for trail in [older, snapped, newer] {
            context.insert(trail)
            trail.layer = layer
        }

        let result = TrailMigrator.ensureTrails(for: layer, in: context)
        XCTAssertEqual(result.map(\.id), [snapped.id])
        XCTAssertEqual(layer.trails?.map(\.id), [snapped.id])
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).map(\.id), [snapped.id])

        // Idempotent.
        XCTAssertEqual(TrailMigrator.ensureTrails(for: layer, in: context).map(\.id), [snapped.id])
    }

    func testDuplicateUnsnappedTrailsKeepEarliest() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let pid = UUID()
        layer.places = [makePlace("Waypoint", lat: 1, lon: 1, pathId: pid, sortIndex: 0, createdAt: t, in: context)]
        let later = Trail(pathId: pid, name: "Later", createdAt: t.addingTimeInterval(5))
        let earliest = Trail(pathId: pid, name: "Earliest", createdAt: t)
        for trail in [later, earliest] {
            context.insert(trail)
            trail.layer = layer
        }

        let result = TrailMigrator.ensureTrails(for: layer, in: context)
        XCTAssertEqual(result.map(\.name), ["Earliest"])
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 1)
    }
}
