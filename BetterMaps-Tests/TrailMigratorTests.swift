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
}
