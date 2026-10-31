import XCTest

/// Directions from a place card to a drawn journey, against the canned
/// planner (`-UITestFakeDirections`). `-openPlaceDetail` opens the first
/// seeded place so the card's Directions tile is reachable without a map tap.
@MainActor
final class DirectionsUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-UITestFakeDirections", "-openPlaceDetail", "YES", "-transit.enabledKinds", "[]"]
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

    func testDirectionsFromPlaceCardDrawsPickedJourney() {
        let app = launch()

        let directions = app.buttons["Directions"]
        XCTAssertTrue(directions.waitForExistence(timeout: 20), "place card's Directions tile missing")
        directions.tap()

        XCTAssertTrue(app.descendants(matching: .any)["directions.results"].waitForExistence(timeout: 10),
                      "directions results did not appear")
        let first = app.buttons["directions.itinerary.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "first itinerary card missing")
        first.tap()

        XCTAssertTrue(app.descendants(matching: .any)["directions.timeline"].waitForExistence(timeout: 6),
                      "picked option's timeline missing")
        // The map's Directions chip stands in for the card only once the
        // card is away; with it up, the card's own close button is the one.
        XCTAssertFalse(app.buttons["directions.clear"].exists,
                       "directions chip should hide while the card is up")
    }
}
