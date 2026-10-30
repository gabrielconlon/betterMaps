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

    /// Directions previews are directions content: like a drawn option, they
    /// replace a favorite's highlighted route. Clearing them (an empty list)
    /// is not drawing anything, so the route stays.
    @MainActor
    func testPreviewsReplaceHighlightedRouteButClearingThemDoesNot() {
        let store = TransitLayerStore()
        let leg = Leg(id: "walk", mode: .walk, fromName: "A", toName: "B",
                      start: Date(), end: Date().addingTimeInterval(600), durationSeconds: 600)

        store.toggleHighlightedRoute("route-mu1", label: "MU1")
        store.setPreviews([])
        XCTAssertEqual(store.highlightedRouteId, "route-mu1", "nothing to draw, nothing to replace")
        XCTAssertEqual(store.highlightedRouteLabel, "MU1")

        store.setPreviews([[leg]])
        XCTAssertNil(store.highlightedRouteId)
        XCTAssertNil(store.highlightedRouteLabel)
        XCTAssertNil(store.highlightedRoute)
        XCTAssertEqual(store.previewItineraries.count, 1)
        XCTAssertTrue(store.hasDirectionsContent)
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
