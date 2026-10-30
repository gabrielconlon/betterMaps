import XCTest
import SwiftData
@testable import CustomMapApp

final class WelcomeWalkthroughTests: XCTestCase {

    // MARK: - Gate

    func testFreshInstallShows() {
        XCTAssertTrue(WelcomeGate.shouldShow(completed: false, arguments: [], isTestHost: false))
        XCTAssertTrue(WelcomeGate.shouldShow(completed: false, arguments: ["-transit.enabledKinds", "[]"],
                                             isTestHost: false),
                      "an unrelated defaults override is not automation")
    }

    func testCompletedHides() {
        XCTAssertFalse(WelcomeGate.shouldShow(completed: true, arguments: [], isTestHost: false))
    }

    func testTestHostNeverShows() {
        XCTAssertFalse(WelcomeGate.shouldShow(completed: false, arguments: [], isTestHost: true))
        XCTAssertFalse(WelcomeGate.shouldShow(completed: false, arguments: [WelcomeGate.forceArgument],
                                              isTestHost: true),
                       "the force flag does not beat the unit-test host")
    }

    func testAutomationArgumentFamiliesHide() {
        // The arguments the UI tests, perf harness and screenshot launches use
        // today, plus a made-up member of each family: the rule is by prefix,
        // so a new flag needs no change here.
        let automation = ["-PerfSeed", "-PerfPan", "-PerfVerbose", "-PerfAnythingNew",
                          "-UITestMapProbe", "-UITestFakeDirections", "-UITestSomethingElse",
                          "-openPlaceDetail", "-openQuickAdd", "-openTrailEditor", "-openLayersPanel",
                          "-openNewScreen", "-sheetMedium"]
        for argument in automation {
            XCTAssertTrue(WelcomeGate.suppresses(argument), "\(argument) is automation")
            XCTAssertFalse(WelcomeGate.shouldShow(completed: false, arguments: [argument], isTestHost: false),
                           "\(argument) must hide the welcome")
            XCTAssertFalse(WelcomeGate.shouldShow(completed: false, arguments: ["-x", argument, "YES"],
                                                  isTestHost: false),
                           "\(argument) hides it wherever it sits")
        }
    }

    func testOrdinaryArgumentsDoNotSuppress() {
        for argument in ["-transit.enabledKinds", "[]", "YES", "-ResetWelcome", "-sheetLarge",
                         "-Open", "UITestMapProbe", "-perfSeed", "-uitest"] {
            XCTAssertFalse(WelcomeGate.suppresses(argument), "\(argument) is not automation")
        }
        XCTAssertEqual(WelcomeGate.suppressingPrefixes, ["-UITest", "-Perf", "-open"])
        XCTAssertEqual(WelcomeGate.suppressingArguments, ["-sheetMedium"])
    }

    func testForceArgumentIsTheOneExceptionToItsPrefix() {
        // `-UITestWelcome` matches the `-UITest` family but is checked first.
        XCTAssertTrue(WelcomeGate.suppresses(WelcomeGate.forceArgument))
        XCTAssertTrue(WelcomeGate.shouldShow(completed: false, arguments: [WelcomeGate.forceArgument],
                                             isTestHost: false))
        XCTAssertTrue(WelcomeGate.shouldShow(completed: true,
                                             arguments: ["-UITestMapProbe", WelcomeGate.forceArgument, "-openQuickAdd"],
                                             isTestHost: false),
                      "the force flag beats every other automation argument")
    }

    func testForceArgumentShowsEvenWhenCompletedOrSeeded() {
        XCTAssertTrue(WelcomeGate.shouldShow(completed: true, arguments: ["-UITestWelcome"], isTestHost: false))
        XCTAssertTrue(WelcomeGate.shouldShow(completed: false, arguments: ["-UITestWelcome", "-PerfSeed"],
                                             isTestHost: false),
                      "the UI test seeds data and still sees the welcome")
        XCTAssertEqual(WelcomeGate.forceArgument, "-UITestWelcome")
        XCTAssertEqual(WelcomeGate.resetArgument, "-ResetWelcome")
    }

    func testResetArgumentAloneDoesNotDecide() {
        // Reset only clears the stored flag; the decision is then the normal one.
        XCTAssertTrue(WelcomeGate.shouldShow(completed: false, arguments: ["-ResetWelcome"], isTestHost: false))
        XCTAssertFalse(WelcomeGate.shouldShow(completed: true, arguments: ["-ResetWelcome"], isTestHost: false))
    }

    func testStorageKey() {
        XCTAssertEqual(WelcomeGate.storageKey, "welcome.completed.v1")
    }

    // MARK: - Pages

    func testPageOrder() {
        XCTAssertEqual(WelcomePage.allCases, [.welcome, .transit, .gettingAround, .done])
        XCTAssertNil(WelcomePage.welcome.previous)
        XCTAssertEqual(WelcomePage.welcome.next, .transit)
        XCTAssertEqual(WelcomePage.done.previous, .gettingAround)
        XCTAssertNil(WelcomePage.done.next)
        XCTAssertTrue(WelcomePage.done.isLast)
        XCTAssertFalse(WelcomePage.gettingAround.isLast)
    }

    // MARK: - Getting around: working copy vs store

    func testPreferencesStateLoadedWinsWhenNothingIsWaiting() {
        var state = WelcomePreferencesState()
        XCTAssertEqual(state.prefs, .default)
        XCTAssertFalse(state.hasUnsavedEdit)
        let stored = DirectionsPreferencesSnapshot.default.replacing(walkToleranceMinutes: 30)
        state.loaded(stored)
        XCTAssertEqual(state.prefs, stored)
        XCTAssertFalse(state.hasUnsavedEdit)
    }

    func testPreferencesStateUnsavedEditIsNeverOverwrittenByARead() {
        var state = WelcomePreferencesState()
        let edit = DirectionsPreferencesSnapshot.default.replacing(allowBikeDirect: true)
        state.edited(edit)
        XCTAssertTrue(state.hasUnsavedEdit)
        state.loaded(.default)
        XCTAssertEqual(state.prefs, edit, "a save notification must not drop the toggle")
        state.saved()
        XCTAssertFalse(state.hasUnsavedEdit)
        state.loaded(.default)
        XCTAssertEqual(state.prefs, .default, "once saved, the store is the truth again")
    }

    @MainActor
    func testLiveRowKeepsACachedRowAndRefetchesADeletedOne() throws {
        let container = try ModelContainer(for: DirectionsPreferences.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        XCTAssertNoThrow(try DirectionsPreferences.ensureRow(in: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DirectionsPreferences>()).count, 1)

        let row = try DirectionsPreferences.liveRow(nil, in: context)
        XCTAssertTrue(try DirectionsPreferences.liveRow(row, in: context) === row, "a live row is reused")

        // Something else (CloudKit, another screen's fetchOrCreate) removed it.
        context.delete(row)
        try context.save()
        let replacement = try DirectionsPreferences.liveRow(row, in: context)
        XCTAssertFalse(replacement === row, "a deleted row is never handed back")
        XCTAssertFalse(replacement.isDeleted)
        replacement.apply(.default.replacing(maxTransfers: 0))
        XCTAssertNoThrow(try context.save(), "the replacement is writable")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DirectionsPreferences>()).count, 1)
    }

    // MARK: - Summary

    func testSummaryLinesForDefaults() {
        let lines = WelcomeSummary.lines(prefs: .default, transitKinds: [])
        XCTAssertEqual(lines.map(\.title), ["On the map", "Walking", "Travel by", "Cycling the whole way"])
        XCTAssertEqual(lines[0].value, "No transit yet")
        XCTAssertEqual(lines[1].value, DirectionsPreferencesSnapshot.default.walkToleranceLabel)
        XCTAssertEqual(lines[2].value, "Bus, Luas, DART, Rail")
        XCTAssertEqual(lines[3].value, DirectionsPreferencesSnapshot.default.allowBikeDirect ? "On" : "Off")
    }

    func testSummaryLinesReflectChoices() {
        let prefs = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 0, enabledModes: [.rail, .bus], allowBikeDirect: true,
            maxTransfers: 1, preferRail: false, preferRailWalkCeilingMinutes: 20,
            rainAware: false, rainProbabilityThreshold: 50)
        let lines = WelcomeSummary.lines(prefs: prefs, transitKinds: [.luas, .bus])
        XCTAssertEqual(lines[0].value, "Bus, Luas", "network order, not set order")
        XCTAssertEqual(lines[1].value, "Walk any distance")
        XCTAssertEqual(lines[2].value, "Bus, Rail")
        XCTAssertEqual(lines[3].value, "On")
    }

    func testSummaryWithNoNetworks() {
        let prefs = DirectionsPreferencesSnapshot.default.replacing(enabledModes: [], allowBikeDirect: false)
        let lines = WelcomeSummary.lines(prefs: prefs, transitKinds: [])
        XCTAssertEqual(lines[2].value, "No networks")
        XCTAssertEqual(lines[3].value, "Off")
    }
}
