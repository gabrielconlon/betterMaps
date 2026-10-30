import XCTest
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

    func testEverySuppressingArgumentHides() {
        let expected: Set<String> = ["-PerfSeed", "-UITestMapProbe", "-UITestFakeDirections",
                                     "-openPlaceDetail", "-openQuickAdd", "-openTrailEditor", "-openLayersPanel"]
        XCTAssertEqual(WelcomeGate.suppressingArguments, expected)
        for argument in expected {
            XCTAssertFalse(WelcomeGate.shouldShow(completed: false, arguments: [argument], isTestHost: false),
                           "\(argument) must hide the welcome")
            XCTAssertFalse(WelcomeGate.shouldShow(completed: false, arguments: ["-x", argument, "YES"],
                                                  isTestHost: false),
                           "\(argument) hides it wherever it sits")
        }
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
