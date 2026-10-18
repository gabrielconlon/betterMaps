import XCTest
import SwiftData
import CoreLocation
@testable import CustomMapApp

@MainActor
final class TrailSnapshotterCacheTests: XCTestCase {

    private func draft(_ coords: [CLLocationCoordinate2D], name: String) -> TrailDraft {
        var d = TrailDraft(name: name)
        for c in coords { d.points.append(TrailPoint(coordinate: c)) }
        return d
    }

    func testRepeatedPassesHitTheCache() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        TrailCommitter.commit(draft([TestCoords.a, TestCoords.b, TestCoords.c], name: "Canal"),
                              geometry: nil, to: layer, trail: nil, in: context)

        let snapshotter = TrailSnapshotter()
        XCTAssertEqual(snapshotter.trails(for: [layer], in: context).map(\.name), ["Canal"])
        XCTAssertEqual(snapshotter.trails(for: [layer], in: context).map(\.name), ["Canal"])
        XCTAssertEqual(snapshotter.rebuildCount, 1)
    }

    func testEditKeepingPointCountRefreshes() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        let trail = TrailCommitter.commit(draft([TestCoords.a, TestCoords.b, TestCoords.c], name: "Canal"),
                                          geometry: nil, to: layer, trail: nil, in: context)
        let snapshotter = TrailSnapshotter()
        let before = snapshotter.trails(for: [layer], in: context)
        XCTAssertEqual(before.first?.segments.first?.snapped, false)

        // Same three points, renamed and snapped: the place count is unchanged.
        var edit = TrailDraft(trail: trail, places: layer.places ?? [])
        edit.name = "Canal loop"
        edit.isSnapped = true
        let detour = TrailGeometry(segments: [
            .init(coordinates: [TestCoords.a, TestCoords.d, TestCoords.b], snapped: true),
            .init(coordinates: [TestCoords.b, TestCoords.c], snapped: true),
        ])
        TrailCommitter.commit(edit, geometry: detour, to: layer, trail: trail, in: context)

        let after = snapshotter.trails(for: [layer], in: context)
        XCTAssertEqual(layer.places?.count, 3)
        XCTAssertEqual(after.map(\.name), ["Canal loop"])
        XCTAssertEqual(after.first?.segments.first?.snapped, true)
        XCTAssertEqual(snapshotter.rebuildCount, 2)
    }

    func testInvalidateForcesRebuild() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        TrailCommitter.commit(draft([TestCoords.a, TestCoords.b], name: "Short"),
                              geometry: nil, to: layer, trail: nil, in: context)
        let snapshotter = TrailSnapshotter()
        _ = snapshotter.trails(for: [layer], in: context)
        snapshotter.invalidate(layerId: layer.id)
        _ = snapshotter.trails(for: [layer], in: context)
        XCTAssertEqual(snapshotter.rebuildCount, 2)
        snapshotter.invalidateAll()
        _ = snapshotter.trails(for: [layer], in: context)
        XCTAssertEqual(snapshotter.rebuildCount, 3)
    }

    func testFingerprintTracksCountsAndNewestUpdate() {
        let t0 = Date(timeIntervalSince1970: 0)
        let base = TrailSnapshotter.Fingerprint(placeCount: 3, trailCount: 1, latestUpdate: t0)
        XCTAssertEqual(base, TrailSnapshotter.Fingerprint(placeCount: 3, trailCount: 1, latestUpdate: t0))
        XCTAssertNotEqual(base, TrailSnapshotter.Fingerprint(placeCount: 3, trailCount: 1,
                                                             latestUpdate: t0.addingTimeInterval(1)))
        XCTAssertNotEqual(base, TrailSnapshotter.Fingerprint(placeCount: 3, trailCount: 2, latestUpdate: t0))
        XCTAssertNotEqual(base, TrailSnapshotter.Fingerprint(placeCount: 4, trailCount: 1, latestUpdate: t0))
    }

    func testHiddenTrailIsNotDrawnAndToggleRefreshes() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        let canal = TrailCommitter.commit(draft([TestCoords.a, TestCoords.b], name: "Canal"),
                                          geometry: nil, to: layer, trail: nil, in: context)
        TrailCommitter.commit(draft([TestCoords.e, TestCoords.f], name: "Park"),
                              geometry: nil, to: layer, trail: nil, in: context)
        let snapshotter = TrailSnapshotter()
        XCTAssertEqual(Set(snapshotter.trails(for: [layer], in: context).map(\.name)), ["Canal", "Park"])

        let before = TrailSnapshotter.fingerprint(in: context)
        TrailCommitter.setVisible(false, for: canal, in: context)
        XCTAssertNotEqual(TrailSnapshotter.fingerprint(in: context), before)
        XCTAssertEqual(snapshotter.trails(for: [layer], in: context).map(\.name), ["Park"])

        TrailCommitter.setVisible(true, for: canal, in: context)
        XCTAssertEqual(Set(snapshotter.trails(for: [layer], in: context).map(\.name)), ["Canal", "Park"])
    }

    func testStoreFingerprintCountsTrails() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let empty = TrailSnapshotter.fingerprint(in: context)
        XCTAssertEqual(empty.trailCount, 0)
        XCTAssertNil(empty.latestUpdate)
        let layer = Layer(name: "Walks", kind: .waypointPath)
        context.insert(layer)
        TrailCommitter.commit(draft([TestCoords.a, TestCoords.b], name: "Canal"),
                              geometry: nil, to: layer, trail: nil, in: context)
        let one = TrailSnapshotter.fingerprint(in: context)
        XCTAssertEqual(one.trailCount, 1)
        XCTAssertNotNil(one.latestUpdate)
    }
}
