import XCTest
@testable import CustomMapApp

final class FirstRunHintsTests: XCTestCase {

    func testFreshStateShowsAllThreeInOrder() {
        let hints = FirstRunHints()
        XCTAssertEqual(hints.visible, [.savePlace, .toggleLayer, .overlap])
        XCTAssertFalse(hints.allDone)
        XCTAssertEqual(hints.rawValue, 0)
    }

    func testMarkDoneSetsBitAndHidesHint() {
        var hints = FirstRunHints()
        hints.markDone(.toggleLayer)
        XCTAssertTrue(hints.isDone(.toggleLayer))
        XCTAssertEqual(hints.rawValue, FirstRunHints.Hint.toggleLayer.rawValue)
        XCTAssertEqual(hints.visible, [.savePlace, .overlap])
    }

    func testMarkDoneIsIdempotent() {
        var hints = FirstRunHints()
        hints.markDone(.overlap)
        hints.markDone(.overlap)
        XCTAssertEqual(hints.rawValue, 4)
    }

    func testRoundTripsThroughRawValue() {
        var hints = FirstRunHints()
        hints.markDone(.savePlace)
        hints.markDone(.overlap)
        let restored = FirstRunHints(rawValue: hints.rawValue)
        XCTAssertEqual(restored, hints)
        XCTAssertEqual(restored.visible, [.toggleLayer])
    }

    func testUnknownBitsAreIgnored() {
        let hints = FirstRunHints(rawValue: 0b1111_1000)
        XCTAssertEqual(hints.rawValue, 0)
        XCTAssertEqual(hints.visible.count, 3)
    }

    func testAllDone() {
        var hints = FirstRunHints()
        FirstRunHints.Hint.allCases.forEach { hints.markDone($0) }
        XCTAssertTrue(hints.allDone)
        XCTAssertTrue(hints.visible.isEmpty)
        XCTAssertEqual(hints.rawValue, 7)
    }

    func testUpdateFromAppState() {
        var hints = FirstRunHints()
        hints.update(placeCount: 0, visibleLayerCount: 1)
        XCTAssertEqual(hints.visible.count, 3, "nothing performed yet")

        hints.update(placeCount: 1, visibleLayerCount: 1)
        XCTAssertTrue(hints.isDone(.savePlace))
        XCTAssertFalse(hints.isDone(.overlap))

        hints.update(placeCount: 1, visibleLayerCount: 2)
        XCTAssertTrue(hints.isDone(.overlap))
        XCTAssertFalse(hints.isDone(.toggleLayer), "toggling is only marked by the toggle action")
        XCTAssertEqual(hints.visible, [.toggleLayer])
    }
}
