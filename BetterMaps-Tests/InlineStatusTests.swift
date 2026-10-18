import XCTest
@testable import CustomMapApp

final class InlineStatusTests: XCTestCase {

    func testLoadingEqualityFollowsText() {
        XCTAssertEqual(InlineStatus.loading("Loading stops…"), .loading("Loading stops…"))
        XCTAssertNotEqual(InlineStatus.loading("Loading stops…"), .loading("Loading routes…"))
    }

    func testEmptyUsesDefaultSystemImage() {
        let implicit = InlineStatus.empty(title: "No places", hint: nil, action: nil)
        let explicit = InlineStatus.empty(title: "No places", hint: nil,
                                          systemImage: "mappin.slash", action: nil)
        XCTAssertEqual(implicit, explicit)
    }

    func testEmptyComparesEveryField() {
        let base = InlineStatus.empty(title: "No places", hint: "Long-press the map",
                                      action: (label: "Add", id: "add"))
        XCTAssertEqual(base, .empty(title: "No places", hint: "Long-press the map",
                                    action: (label: "Add", id: "add")))
        XCTAssertNotEqual(base, .empty(title: "No layers", hint: "Long-press the map",
                                       action: (label: "Add", id: "add")))
        XCTAssertNotEqual(base, .empty(title: "No places", hint: nil,
                                       action: (label: "Add", id: "add")))
        XCTAssertNotEqual(base, .empty(title: "No places", hint: "Long-press the map",
                                       systemImage: "tray", action: (label: "Add", id: "add")))
        XCTAssertNotEqual(base, .empty(title: "No places", hint: "Long-press the map",
                                       action: (label: "Add", id: "other")))
        XCTAssertNotEqual(base, .empty(title: "No places", hint: "Long-press the map",
                                       action: (label: "Create", id: "add")))
        XCTAssertNotEqual(base, .empty(title: "No places", hint: "Long-press the map",
                                       action: nil))
    }

    func testFailedComparesMessageAndRetryId() {
        let base = InlineStatus.failed(message: "Couldn't load arrivals.", retryId: "arrivals")
        XCTAssertEqual(base, .failed(message: "Couldn't load arrivals.", retryId: "arrivals"))
        XCTAssertNotEqual(base, .failed(message: "Couldn't load arrivals.", retryId: nil))
        XCTAssertNotEqual(base, .failed(message: "Something else.", retryId: "arrivals"))
    }

    func testDifferentCasesAreNeverEqual() {
        XCTAssertNotEqual(InlineStatus.loading("x"), .failed(message: "x", retryId: nil))
        XCTAssertNotEqual(InlineStatus.loading("x"), .empty(title: "x", hint: nil, action: nil))
        XCTAssertNotEqual(InlineStatus.failed(message: "x", retryId: nil),
                          .empty(title: "x", hint: nil, action: nil))
    }
}
