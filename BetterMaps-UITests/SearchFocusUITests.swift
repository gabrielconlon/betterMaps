import XCTest

/// Search stays focused after a tap. On an iOS 18 iPhone 12 Pro the field
/// lost focus right after every tap (a map camera settle dismissed it), so
/// the keyboard never stayed up. Run this on an iOS 18 simulator as well as
/// the current one.
@MainActor
final class SearchFocusUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSearchStaysFocusedWhileTheMapSettles() {
        let app = XCUIApplication()
        // Transit on, so its load nudges the camera while search is focused.
        app.launchArguments = ["-transit.enabledKinds", #"["bus","dart","luas","rail"]"#]
        app.launch()
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK", "Don’t Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        let field = app.textFields["Search places, stops, routes"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "search field missing")
        field.tap()
        // A location prompt on first focus takes focus; the next tap lets the
        // interruption monitor answer it, then focuses again.
        if !app.buttons["Cancel"].waitForExistence(timeout: 3) { field.tap() }

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "search never took focus")
        // Long enough for launch and transit-load camera settles to land.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(cancel.exists, "search lost focus while the map settled")
        XCTAssertTrue(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false,
                      "search field no longer has keyboard focus")

        field.typeText("Pearse")
        XCTAssertEqual(field.value as? String, "Pearse")
    }
}
