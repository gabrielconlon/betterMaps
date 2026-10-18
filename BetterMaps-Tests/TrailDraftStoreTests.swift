import XCTest
@testable import CustomMapApp

@MainActor
final class TrailDraftStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TrailDraftStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testRoundTripsThroughFreshStore() throws {
        var draft = TrailDraft(name: "Canal", isSnapped: true)
        draft.add(TestCoords.a)
        draft.add(TestCoords.b)
        draft.toggleEndpoint(draft.points[1].id)
        XCTAssertTrue(draft.canUndo)

        let layerId = UUID()
        let trailId = UUID()
        let store = TrailDraftStore(defaults: defaults)
        XCTAssertFalse(store.hasDraft)
        store.save(draft, layerId: layerId, trailId: trailId)
        XCTAssertTrue(store.hasDraft)

        // A new store on the same defaults simulates a relaunch.
        let relaunched = TrailDraftStore(defaults: defaults)
        let pending = try XCTUnwrap(relaunched.pending)
        XCTAssertEqual(pending.layerId, layerId)
        XCTAssertEqual(pending.trailId, trailId)
        XCTAssertEqual(pending.draft.points, draft.points)
        XCTAssertEqual(pending.draft.name, "Canal")
        XCTAssertTrue(pending.draft.isSnapped)
        XCTAssertFalse(pending.draft.canUndo, "undo history is not persisted")

        XCTAssertNotNil(relaunched.pending(layerId: layerId, trailId: trailId))
        XCTAssertNil(relaunched.pending(layerId: layerId, trailId: nil))
        XCTAssertNil(relaunched.pending(layerId: UUID(), trailId: trailId))
    }

    func testClear() {
        let store = TrailDraftStore(defaults: defaults)
        let layerId = UUID()
        store.save(TrailDraft(points: [TrailPoint(coordinate: TestCoords.a)]), layerId: layerId, trailId: nil)

        store.clear(layerId: UUID(), trailId: nil)
        XCTAssertTrue(store.hasDraft, "clearing another layer's draft is a no-op")

        store.clear(layerId: layerId, trailId: nil)
        XCTAssertFalse(store.hasDraft)
        XCTAssertNil(TrailDraftStore(defaults: defaults).pending)

        store.save(TrailDraft(), layerId: layerId, trailId: nil)
        store.clear()
        XCTAssertNil(store.pending)
        XCTAssertNil(defaults.data(forKey: TrailDraftStore.defaultsKey))
    }
}
