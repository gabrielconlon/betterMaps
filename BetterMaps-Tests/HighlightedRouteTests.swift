import XCTest
@testable import CustomMapApp

/// The map's clear-route chip reads the highlighted route's id and label;
/// both must go together, or the chip outlives the route (or vice versa).
final class HighlightedRouteTests: XCTestCase {
    @MainActor
    func testToggleSetsLabelAndSecondToggleClearsIt() {
        let store = TransitLayerStore()
        store.toggleHighlightedRoute("route-mu1", label: "MU1")
        XCTAssertEqual(store.highlightedRouteId, "route-mu1")
        XCTAssertEqual(store.highlightedRouteLabel, "MU1")

        store.toggleHighlightedRoute("route-mu1", label: "MU1")
        XCTAssertNil(store.highlightedRouteId)
        XCTAssertNil(store.highlightedRouteLabel)
    }

    @MainActor
    func testSwitchingRoutesReplacesLabel() {
        let store = TransitLayerStore()
        store.toggleHighlightedRoute("route-mu1", label: "MU1")
        store.toggleHighlightedRoute("route-39a")
        XCTAssertEqual(store.highlightedRouteId, "route-39a")
        XCTAssertNil(store.highlightedRouteLabel)
        store.clearHighlightedRoute()
    }

    @MainActor
    func testClearDropsRouteAndLabel() {
        let store = TransitLayerStore()
        store.toggleHighlightedRoute("route-mu1", label: "MU1")
        store.clearHighlightedRoute()
        XCTAssertNil(store.highlightedRouteId)
        XCTAssertNil(store.highlightedRouteLabel)
        XCTAssertNil(store.highlightedRoute)
    }
}
