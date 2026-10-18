import XCTest
@testable import CustomMapApp

final class SheetLayoutTests: XCTestCase {
    // iPhone 17-ish: 874pt screen, 62pt top inset, 34pt home indicator.
    let layout = SheetLayout(availableHeight: 812, bottomInset: 34)

    func testHeightsAreOrdered() {
        XCTAssertEqual(layout.collapsed, SheetLayout.collapsedContentHeight + 34)
        XCTAssertLessThan(layout.collapsed, layout.medium)
        XCTAssertLessThan(layout.medium, layout.expanded)
        XCTAssertEqual(layout.medium, 812 * 0.45, accuracy: 0.5)
        XCTAssertLessThanOrEqual(layout.expanded, 812 - 24)
    }

    func testSlowReleaseSnapsToNearest() {
        // Dragged up a little from collapsed: back to collapsed.
        XCTAssertEqual(layout.snap(from: .collapsed, translation: -40, velocity: 0), .collapsed)
        // Dragged most of the way to medium: medium.
        let toMedium = layout.collapsed - layout.medium + 30
        XCTAssertEqual(layout.snap(from: .collapsed, translation: toMedium, velocity: 0), .medium)
        // Dragged down from expanded past medium: medium or collapsed by distance.
        XCTAssertEqual(layout.snap(from: .expanded, translation: layout.expanded - layout.medium, velocity: 0), .medium)
    }

    func testFlickMovesOneDetentInItsDirection() {
        XCTAssertEqual(layout.snap(from: .collapsed, translation: -10, velocity: -1200), .medium)
        XCTAssertEqual(layout.snap(from: .medium, translation: -10, velocity: -1200), .expanded)
        XCTAssertEqual(layout.snap(from: .expanded, translation: 10, velocity: 1200), .medium)
        XCTAssertEqual(layout.snap(from: .medium, translation: 10, velocity: 1200), .collapsed)
        XCTAssertEqual(layout.snap(from: .expanded, translation: -10, velocity: -1200), .expanded)
        XCTAssertEqual(layout.snap(from: .collapsed, translation: 10, velocity: 1200), .collapsed)
    }

    func testGrabberCycle() {
        XCTAssertEqual(SheetDetent.collapsed.cycled, .medium)
        XCTAssertEqual(SheetDetent.medium.cycled, .expanded)
        XCTAssertEqual(SheetDetent.expanded.cycled, .collapsed)
    }

    func testTinyContainerNeverInverts() {
        let tiny = SheetLayout(availableHeight: 200, bottomInset: 0)
        XCTAssertLessThanOrEqual(tiny.collapsed, tiny.medium)
        XCTAssertLessThanOrEqual(tiny.medium, tiny.expanded)
    }
}
