import XCTest
import SwiftData
@testable import CustomMapApp

@MainActor
final class DirectionsPreferencesTests: XCTestCase {
    private func snapshot(walk: Int = 10, transfers: Int = 2, ceiling: Int = 20,
                          threshold: Int = 50, cycling: CyclingStyle = .quiet) -> DirectionsPreferencesSnapshot {
        DirectionsPreferencesSnapshot(
            walkToleranceMinutes: walk, enabledModes: [.bus, .dart], allowBikeDirect: false,
            maxTransfers: transfers, preferRail: false, preferRailWalkCeilingMinutes: ceiling,
            rainAware: false, rainProbabilityThreshold: threshold, cyclingStyle: cycling
        )
    }

    // MARK: Snapshot clamping

    func testWalkToleranceSnapsToNearestStep() {
        // 7 is 2 from 5 and 3 from 10, so it snaps down.
        XCTAssertEqual(snapshot(walk: 7).walkToleranceMinutes, 5)
        XCTAssertEqual(snapshot(walk: 8).walkToleranceMinutes, 10)
        XCTAssertEqual(snapshot(walk: 25).walkToleranceMinutes, 20)
        XCTAssertEqual(snapshot(walk: 0).walkToleranceMinutes, 5)
        XCTAssertEqual(snapshot(walk: 15).walkToleranceMinutes, 15)
    }

    func testTransfersCeilingAndThresholdAreClamped() {
        XCTAssertEqual(snapshot(transfers: 9).maxTransfers, 4)
        XCTAssertEqual(snapshot(transfers: -1).maxTransfers, 0)
        XCTAssertEqual(snapshot(ceiling: 90).preferRailWalkCeilingMinutes, 60)
        XCTAssertEqual(snapshot(ceiling: -5).preferRailWalkCeilingMinutes, 0)
        XCTAssertEqual(snapshot(threshold: 150).rainProbabilityThreshold, 100)
        XCTAssertEqual(snapshot(threshold: -10).rainProbabilityThreshold, 0)
    }

    func testDefaultValues() {
        let d = DirectionsPreferencesSnapshot.default
        XCTAssertEqual(d.walkToleranceMinutes, 10)
        XCTAssertEqual(d.enabledModes, [.bus, .luas, .dart, .rail])
        XCTAssertTrue(d.allowBikeDirect)
        XCTAssertEqual(d.maxTransfers, 2)
        XCTAssertTrue(d.preferRail)
        XCTAssertEqual(d.preferRailWalkCeilingMinutes, 20)
        XCTAssertTrue(d.rainAware)
        XCTAssertEqual(d.rainProbabilityThreshold, 50)
        XCTAssertEqual(d.cyclingStyle, .quiet)
        XCTAssertEqual(d.allowedTransitModes, [.bus, .luas, .dart, .rail])
    }

    func testCyclingStyleDefaultsToQuietWhenOmitted() {
        let s = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 10, enabledModes: [.bus], allowBikeDirect: true,
            maxTransfers: 2, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50)
        XCTAssertEqual(s.cyclingStyle, .quiet)
        XCTAssertEqual(s.replacing(cyclingStyle: .fast).cyclingStyle, .fast)
        XCTAssertEqual(s.replacing(cyclingStyle: .fast).replacing(walkToleranceMinutes: 20).cyclingStyle, .fast,
                       "other replacements keep the style")
    }

    func testAllowedTransitModesDropsWalkAndBike() {
        let s = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 10, enabledModes: [.bus, .walk, .bike], allowBikeDirect: true,
            maxTransfers: 2, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50
        )
        XCTAssertEqual(s.allowedTransitModes, [.bus])
    }

    // MARK: Model

    func testFreshModelMatchesDefaultSnapshot() {
        XCTAssertEqual(DirectionsPreferences().snapshot, .default)
    }

    func testApplyRoundTripsAndBumpsUpdatedAt() throws {
        let container = AppModelContainer.makeInMemory()
        let context = container.mainContext
        let prefs = DirectionsPreferences()
        context.insert(prefs)
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.updatedAt = before

        let custom = snapshot(walk: 15, transfers: 1, ceiling: 30, threshold: 70, cycling: .balanced)
        prefs.apply(custom)
        try context.save()

        XCTAssertEqual(prefs.snapshot, custom)
        XCTAssertEqual(prefs.enabledModesRaw, ["bus", "dart"])
        XCTAssertEqual(prefs.cyclingStyleRaw, "balanced")
        XCTAssertGreaterThan(prefs.updatedAt, before)
    }

    func testUnknownCyclingStyleReadsAsQuiet() {
        let prefs = DirectionsPreferences()
        XCTAssertEqual(prefs.cyclingStyleRaw, "quiet", "the stored default")
        prefs.cyclingStyleRaw = "hoverboard"
        XCTAssertEqual(prefs.snapshot.cyclingStyle, .quiet)
        prefs.cyclingStyleRaw = "fast"
        XCTAssertEqual(prefs.snapshot.cyclingStyle, .fast)
    }

    func testFetchOrCreateOnEmptyContextInsertsOneRow() throws {
        let container = AppModelContainer.makeInMemory()
        let context = container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DirectionsPreferences>()), 0)

        let prefs = try DirectionsPreferences.fetchOrCreate(in: context)
        try context.save()

        XCTAssertEqual(prefs.snapshot, .default)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DirectionsPreferences>()), 1)

        // A second call finds the same row rather than inserting another.
        let again = try DirectionsPreferences.fetchOrCreate(in: context)
        XCTAssertTrue(again === prefs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DirectionsPreferences>()), 1)
    }

    func testFetchOrCreateKeepsNewestAndDeletesExtras() throws {
        let container = AppModelContainer.makeInMemory()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let oldest = DirectionsPreferences(snapshot: snapshot(walk: 5))
        let newest = DirectionsPreferences(snapshot: snapshot(walk: 20))
        let middle = DirectionsPreferences(snapshot: snapshot(walk: 15))
        for row in [oldest, newest, middle] { context.insert(row) }
        oldest.updatedAt = base
        newest.updatedAt = base.addingTimeInterval(200)
        middle.updatedAt = base.addingTimeInterval(100)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DirectionsPreferences>()), 3)

        let kept = try DirectionsPreferences.fetchOrCreate(in: context)
        try context.save()

        XCTAssertTrue(kept === newest)
        XCTAssertEqual(kept.walkToleranceMinutes, 20)
        let remaining = try context.fetch(FetchDescriptor<DirectionsPreferences>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.walkToleranceMinutes, 20)
    }
}
