import XCTest
@testable import CustomMapApp

@MainActor
final class ToastCenterTests: XCTestCase {

    func testStartsEmpty() {
        XCTAssertNil(ToastCenter().current)
    }

    func testShowSetsCurrentWithDefaults() throws {
        let center = ToastCenter()
        center.show("Place saved")
        let toast = try XCTUnwrap(center.current)
        XCTAssertEqual(toast.message, "Place saved")
        XCTAssertEqual(toast.duration, .seconds(2))
        XCTAssertNil(toast.action)
    }

    func testSecondShowReplacesFirst() throws {
        let center = ToastCenter()
        center.show("Place saved")
        let first = try XCTUnwrap(center.current)
        center.show("Layer created")
        let second = try XCTUnwrap(center.current)
        XCTAssertEqual(second.message, "Layer created")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)
    }

    func testRepeatingSameMessageIsANewPresentation() throws {
        let center = ToastCenter()
        center.show("Saved")
        let first = try XCTUnwrap(center.current)
        center.show("Saved")
        // A new id restarts the auto-dismiss timer (.task(id:)).
        XCTAssertNotEqual(first.id, try XCTUnwrap(center.current).id)
    }

    func testDurationIsPreserved() throws {
        let center = ToastCenter()
        center.show("Copied", duration: .milliseconds(3500))
        XCTAssertEqual(try XCTUnwrap(center.current).duration, .milliseconds(3500))
    }

    func testActionIsPreservedAndInvokable() throws {
        let center = ToastCenter()
        var undone = false
        center.show("Place deleted", action: ToastAction(label: "Undo") { undone = true })
        let action = try XCTUnwrap(center.current?.action)
        XCTAssertEqual(action.label, "Undo")
        action.handler()
        XCTAssertTrue(undone)
    }

    func testDismissClearsCurrent() {
        let center = ToastCenter()
        center.show("Saved")
        center.dismiss()
        XCTAssertNil(center.current)
    }
}
