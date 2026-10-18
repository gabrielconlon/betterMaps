import XCTest

/// Real-touch checks of the map's own gestures. The app is launched with
/// `-UITestMapProbe`, which exposes the settled map centre as the value of
/// an invisible accessibility element (`debug.mapCenter`).
@MainActor
final class MapPanUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: - Launch

    private enum Transit { case off, all }

    private func launch(transit: Transit = .off) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-UITestMapProbe"]
        #if targetEnvironment(simulator)
        // Realistic data. Never on a device: it writes into the owner's
        // iCloud-synced store.
        args.append("-PerfSeed")
        #endif
        switch transit {
        case .off: args += ["-transit.enabledKinds", "[]"]
        case .all: args += ["-transit.enabledKinds", #"["bus","dart","luas","rail"]"#]
        }
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

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["debug.mapCenter"]
    }

    private func center(_ app: XCUIApplication) -> String {
        probe(app).value as? String ?? "none"
    }

    /// Waits for the first settled centre, then for the value to stop
    /// changing (launch and transit loads can nudge it).
    private func waitForSettledCenter(_ app: XCUIApplication, timeout: TimeInterval = 20) -> String {
        XCTAssertTrue(probe(app).waitForExistence(timeout: timeout), "map probe missing")
        let deadline = Date().addingTimeInterval(timeout)
        var last = center(app)
        while last == "none", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            last = center(app)
        }
        XCTAssertNotEqual(last, "none", "map never reported a settled centre")
        // Stable for 1 s.
        var stableSince = Date()
        while Date() < deadline, Date().timeIntervalSince(stableSince) < 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let now = center(app)
            if now != last { last = now; stableSince = Date() }
        }
        return last
    }

    /// Polls until the centre differs from `old` (or `timeout`).
    private func waitForCenter(_ app: XCUIApplication, toChangeFrom old: String,
                               timeout: TimeInterval = 6) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var now = center(app)
        while now == old, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            now = center(app)
        }
        // Let the settle finish.
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        return center(app)
    }

    private static func parse(_ s: String) -> (lat: Double, lon: Double)? {
        let parts = s.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private func assertMoved(from before: String, to after: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let a = Self.parse(before), let b = Self.parse(after) else {
            return XCTFail("unparseable centres \(before) → \(after)", file: file, line: line)
        }
        let moved = abs(a.lat - b.lat) + abs(a.lon - b.lon)
        print("MAPPAN centre \(before) -> \(after) moved=\(moved)")
        XCTAssertGreaterThan(moved, 0.005, "map did not pan: \(before) → \(after)", file: file, line: line)
    }

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: from)
        let end = window.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: - Tests

    func testOneFingerDragPansMap() {
        let app = launch()
        let before = waitForSettledCenter(app)
        drag(app, from: CGVector(dx: 0.3, dy: 0.4), to: CGVector(dx: 0.7, dy: 0.55))
        assertMoved(from: before, to: waitForCenter(app, toChangeFrom: before))
    }

    func testOneFingerDragPansMapWithAllTransit() {
        let app = launch(transit: .all)
        let before = waitForSettledCenter(app)
        drag(app, from: CGVector(dx: 0.3, dy: 0.4), to: CGVector(dx: 0.7, dy: 0.55))
        assertMoved(from: before, to: waitForCenter(app, toChangeFrom: before))
    }

    func testSwipeAfterIdlePansMap() {
        let app = launch()
        let before = waitForSettledCenter(app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4))
            .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        assertMoved(from: before, to: waitForCenter(app, toChangeFrom: before))
    }

    func testDragAfterTapPansMap() {
        let app = launch()
        let before = waitForSettledCenter(app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // The lookup sheet (if any) sits low and lets the map be dragged
        // above it.
        drag(app, from: CGVector(dx: 0.3, dy: 0.2), to: CGVector(dx: 0.7, dy: 0.35))
        assertMoved(from: before, to: waitForCenter(app, toChangeFrom: before))
    }

    func testLongPressDropsPin() {
        let app = launch()
        _ = waitForSettledCenter(app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.8)
        // A location-permission alert may sit over the sheet; the sheet's
        // button is still in the hierarchy.
        XCTAssertTrue(app.buttons["More details…"].waitForExistence(timeout: 6),
                      "quick-add sheet did not appear after a long press")
    }
}
