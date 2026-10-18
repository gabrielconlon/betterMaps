import XCTest
@testable import CustomMapApp

final class FirstRunHintsTests: XCTestCase {

    func testFreshStateShowsOnlyTheFirstHint() {
        let hints = FirstRunHints()
        XCTAssertEqual(hints.visible, [.savePlace], "one hint at a time")
        XCTAssertFalse(hints.allDone)
        XCTAssertEqual(hints.rawValue, 0)
    }

    func testMarkDoneSetsBitAndAdvances() {
        var hints = FirstRunHints()
        hints.markDone(.toggleLayer)
        XCTAssertTrue(hints.isDone(.toggleLayer))
        XCTAssertEqual(hints.rawValue, FirstRunHints.Hint.toggleLayer.rawValue)
        XCTAssertEqual(hints.visible, [.savePlace])
        hints.markDone(.savePlace)
        XCTAssertEqual(hints.visible, [.overlap], "skips the done hint")
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
        XCTAssertEqual(hints.visible, [.savePlace])
    }

    func testAllDone() {
        var hints = FirstRunHints()
        FirstRunHints.Hint.allCases.forEach { hints.markDone($0) }
        XCTAssertTrue(hints.allDone)
        XCTAssertTrue(hints.visible.isEmpty)
        XCTAssertNil(hints.current(hasLayers: true))
        XCTAssertEqual(hints.rawValue, 7)
    }

    func testUpdateFromAppState() {
        var hints = FirstRunHints()
        hints.update(placeCount: 0, visibleLayerCount: 1)
        XCTAssertEqual(hints.rawValue, 0, "nothing performed yet")

        hints.update(placeCount: 1, visibleLayerCount: 1)
        XCTAssertTrue(hints.isDone(.savePlace))

        hints.update(placeCount: 1, visibleLayerCount: 3)
        XCTAssertFalse(hints.isDone(.overlap), "showing layers is not using Overlap only")
        XCTAssertFalse(hints.isDone(.toggleLayer), "toggling is only marked by the toggle action")
        XCTAssertEqual(hints.visible, [.toggleLayer])
    }

    func testCurrentDefersSavePlaceToTheEmptyState() {
        let fresh = FirstRunHints()
        XCTAssertNil(fresh.current(hasLayers: false), "the No layers yet state already says it")
        XCTAssertEqual(fresh.current(hasLayers: true), .savePlace)

        var later = FirstRunHints()
        later.markDone(.savePlace)
        XCTAssertEqual(later.current(hasLayers: false), .toggleLayer)
        later.markDone(.toggleLayer)
        XCTAssertEqual(later.current(hasLayers: true), .overlap)
    }

    func testHintWordingUsesLayersAndTags() {
        XCTAssertEqual(FirstRunHints.Hint.toggleLayer.text, "Tap Layers to choose what's on the map")
        XCTAssertEqual(FirstRunHints.Hint.overlap.text, "Pick two tags and choose All to see places that have both")
    }
}
