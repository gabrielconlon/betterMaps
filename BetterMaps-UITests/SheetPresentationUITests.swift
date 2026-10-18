import XCTest

/// One panel at a time: while a system sheet (quick add, place detail,
/// arrivals…) is up, the map's own bottom sheet is gone, and it comes back
/// when the system sheet is dismissed.
@MainActor
final class SheetPresentationUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-UITestMapProbe", "-transit.enabledKinds", "[]"] + extra
        #if targetEnvironment(simulator)
        // Never on a device: it writes into the owner's iCloud-synced store.
        args.append("-PerfSeed")
        #endif
        app.launchArguments = args
        app.launch()
        return app
    }

    /// The long press asks for location the first time; answer it.
    private func dismissLocationAlertIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        for label in ["Allow While Using App", "Allow Once", "OK", "Don’t Allow"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func testMapSheetHidesWhileSystemSheetIsUp() {
        assertHidesAndReturns(launchArgs: [], expectedDetent: "Collapsed")
    }

    /// The map sheet comes back at the detent it had, not collapsed.
    func testMapSheetReturnsAtItsDetent() {
        assertHidesAndReturns(launchArgs: ["-sheetMedium"], expectedDetent: "Half height")
    }

    private func assertHidesAndReturns(launchArgs: [String], expectedDetent: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(extra: launchArgs)
        let search = app.textFields["sheet.search"]
        let grabber = app.buttons["Search and saved places"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "map sheet search field missing at launch",
                      file: file, line: line)
        XCTAssertTrue(waitUntil(5) { search.isHittable }, "map sheet search field not hittable at launch",
                      file: file, line: line)
        XCTAssertEqual(grabber.value as? String, expectedDetent, file: file, line: line)

        // Long-press the map (above any sheet) to open quick add.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.8)
        dismissLocationAlertIfShown()

        let moreDetails = app.buttons["More details…"]
        XCTAssertTrue(moreDetails.waitForExistence(timeout: 6), "quick-add sheet did not appear",
                      file: file, line: line)
        // Gone means out of the accessibility tree, or slid below the screen.
        let isGone = waitUntil(3) { !search.exists || search.frame.minY >= window.frame.maxY - 1 }
        XCTAssertTrue(isGone, "map sheet still on screen under the quick-add sheet (search at \(search.frame))",
                      file: file, line: line)

        // Swipe the quick-add sheet away by its grabber.
        let systemGrabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(systemGrabber.exists, "quick-add sheet grabber missing", file: file, line: line)
        systemGrabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)),
                   withVelocity: .fast, thenHoldForDuration: 0)

        XCTAssertTrue(waitUntil(5) { !moreDetails.exists }, "quick-add sheet did not dismiss",
                      file: file, line: line)
        XCTAssertTrue(search.waitForExistence(timeout: 5), "map sheet did not come back", file: file, line: line)
        XCTAssertTrue(waitUntil(5) { search.isHittable }, "map sheet search field not hittable after dismiss",
                      file: file, line: line)
        XCTAssertEqual(grabber.value as? String, expectedDetent, "map sheet came back at another detent",
                       file: file, line: line)
    }
}
