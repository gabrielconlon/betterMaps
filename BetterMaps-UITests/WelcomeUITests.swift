import XCTest

/// The first-run welcome, forced on with `-UITestWelcome`: every page is
/// reachable with Next, the cycling switch on Getting around flips, and
/// Start exploring hands the map back.
@MainActor
final class WelcomeUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Defaults overrides come first: the argument domain reads `-key value`
        // pairs, so a bare flag before one would swallow its key.
        var args = ["-transit.enabledKinds", "[]", "-UITestWelcome"]
        #if targetEnvironment(simulator)
        // Realistic data. Never on a device: it writes into the owner's
        // iCloud-synced store.
        args.append("-PerfSeed")
        #endif
        app.launchArguments = args
        app.launch()
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK", "Don’t Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        return app
    }

    private func page(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.descendants(matching: .any)["welcome.page.\(index)"]
    }

    func testWalkthroughPagesThenStartExploring() {
        let app = launch()

        XCTAssertTrue(page(app, 0).waitForExistence(timeout: 20), "welcome page missing")
        XCTAssertTrue(app.staticTexts["Welcome to BetterMaps"].exists, "first headline missing")
        XCTAssertFalse(app.buttons["welcome.back"].exists, "no Back on the first page")

        let next = app.buttons["welcome.next"]
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(page(app, 1).waitForExistence(timeout: 5), "transit page missing")
        XCTAssertTrue(app.staticTexts["Transit on the map"].exists)
        XCTAssertTrue(app.buttons["welcome.transit.bus"].exists, "network tiles missing")

        next.tap()
        XCTAssertTrue(page(app, 2).waitForExistence(timeout: 5), "getting around page missing")
        XCTAssertTrue(app.staticTexts["Getting around"].exists)

        // Flip cycling the whole way and check it took.
        let cycling = app.switches["directions.bikeDirect"]
        XCTAssertTrue(cycling.waitForExistence(timeout: 5), "cycling switch missing")
        let before = cycling.value as? String
        cycling.tap()
        let deadline = Date().addingTimeInterval(3)
        while (cycling.value as? String) == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotEqual(cycling.value as? String, before, "cycling switch did not flip")

        // Back returns to the previous page; Next moves on again.
        app.buttons["welcome.back"].tap()
        XCTAssertTrue(page(app, 1).waitForExistence(timeout: 5), "Back did not return to transit")
        next.tap()
        XCTAssertTrue(page(app, 2).waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(page(app, 3).waitForExistence(timeout: 5), "done page missing")
        XCTAssertTrue(app.staticTexts["You're set"].exists)
        XCTAssertFalse(next.exists, "Next is replaced by Start exploring on the last page")

        let done = app.buttons["welcome.done"]
        XCTAssertTrue(done.isHittable)
        done.tap()

        let layers = app.buttons["Layers"]
        XCTAssertTrue(layers.waitForExistence(timeout: 10), "map chrome missing after the welcome")
        XCTAssertTrue(layers.isHittable, "Layers button not reachable after the welcome")
        XCTAssertFalse(page(app, 3).exists, "the welcome stayed up")
    }
}
