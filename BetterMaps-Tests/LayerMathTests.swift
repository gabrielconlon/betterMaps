import XCTest
@testable import CustomMapApp

final class LayerMathTests: XCTestCase {

    // Fixtures: two visible place layers, one visible trail layer, one hidden place layer.
    let brunch = LayerLite(id: UUID(), name: "Brunch", sortOrder: 0)
    let favorites = LayerLite(id: UUID(), name: "Favorites", sortOrder: 1)
    let coffee = LayerLite(id: UUID(), name: "Coffee", sortOrder: 2)
    let trail = LayerLite(id: UUID(), name: "Canal Walk", kind: .waypointPath, sortOrder: 3)
    let hidden = LayerLite(id: UUID(), name: "Hidden", isVisible: false, sortOrder: 4)

    var layers: [LayerLite] { [brunch, favorites, coffee, trail, hidden] }

    func place(_ name: String, in layerIds: [UUID], endpoint: Bool = false) -> PlaceLite {
        PlaceLite(id: UUID(), name: name, layerIds: layerIds, isEndpoint: endpoint)
    }

    // MARK: - Visible sets

    func testVisibleSetsSplitByKind() {
        XCTAssertEqual(LayerMath.visiblePlaceLayerIds(layers), [brunch.id, favorites.id, coffee.id])
        XCTAssertEqual(LayerMath.visibleTrailLayerIds(layers), [trail.id])
    }

    func testMatchCountCountsOnlyVisibleIds() {
        let p = place("x", in: [brunch.id, hidden.id, trail.id])
        XCTAssertEqual(LayerMath.matchCount(p, visible: LayerMath.visiblePlaceLayerIds(layers)), 1)
        XCTAssertEqual(LayerMath.matchCount(p, visible: [brunch.id, hidden.id]), 2)
        XCTAssertEqual(LayerMath.matchCount(p, visible: []), 0)
    }

    // MARK: - Union

    func testUnionShowsAnyVisiblePlaceMembership() {
        let inBrunch = place("brunch only", in: [brunch.id])
        let inHidden = place("hidden only", in: [hidden.id])
        let orphan = place("none", in: [])
        let both = place("both", in: [favorites.id, brunch.id])

        let out = LayerMath.filter([inBrunch, inHidden, orphan, both], layers: layers, mode: .union)
        XCTAssertEqual(out.map(\.id), [inBrunch.id, both.id], "order preserved, hidden/orphan dropped")
        XCTAssertEqual(out[0].matchCount, 1)
        XCTAssertEqual(out[1].matchCount, 2)
    }

    func testPrimaryLayerIsLowestSortOrderVisibleLayer() {
        let p = place("p", in: [coffee.id, favorites.id, brunch.id, hidden.id])
        let out = LayerMath.filter([p], layers: layers, mode: .union)
        XCTAssertEqual(out.first?.primaryLayerId, brunch.id)
    }

    func testNoVisibleLayersYieldsNothing() {
        let p = place("p", in: [hidden.id])
        XCTAssertTrue(LayerMath.filter([p], layers: [hidden], mode: .union).isEmpty)
        XCTAssertTrue(LayerMath.filter([p], layers: [], mode: .intersection).isEmpty)
    }

    // MARK: - Intersection

    func testIntersectionIgnoresVisibleTrailLayer() {
        // Three visible place layers: brunch, favorites, coffee. Only `coffee` hidden here.
        let visible = [brunch, favorites, trail]
        let shared = place("shared", in: [brunch.id, favorites.id])
        let brunchOnly = place("brunch", in: [brunch.id])
        let sharedPlusTrail = place("shared+trail", in: [brunch.id, favorites.id, trail.id])

        let out = LayerMath.filter([shared, brunchOnly, sharedPlusTrail], layers: visible, mode: .intersection)
        XCTAssertEqual(out.map(\.id), [shared.id, sharedPlusTrail.id],
                       "a visible trail layer must not be required for intersection")
        XCTAssertEqual(out.map(\.matchCount), [2, 2], "trail membership never counts")
    }

    func testIntersectionRequiresEveryVisiblePlaceLayer() {
        let twoOfThree = place("two", in: [brunch.id, favorites.id])
        let all = place("all", in: [brunch.id, favorites.id, coffee.id])
        let out = LayerMath.filter([twoOfThree, all], layers: layers, mode: .intersection)
        XCTAssertEqual(out.map(\.id), [all.id])
    }

    // MARK: - Trail rule

    func testTrailOnlyNonEndpointHiddenEndpointShown() {
        let mid = place("mid", in: [trail.id], endpoint: false)
        let end = place("end", in: [trail.id], endpoint: true)

        for mode in FilterMode.allCases {
            let out = LayerMath.filter([mid, end], layers: layers, mode: mode)
            XCTAssertEqual(out.map(\.id), [end.id], "mode \(mode)")
            XCTAssertEqual(out.first?.matchCount, 0)
            XCTAssertEqual(out.first?.primaryLayerId, trail.id)
        }
    }

    func testTrailMidpointAlsoInVisiblePlaceLayerShows() {
        let mid = place("mid", in: [trail.id, brunch.id], endpoint: false)
        let out = LayerMath.filter([mid], layers: layers, mode: .union)
        XCTAssertEqual(out.map(\.id), [mid.id])
        XCTAssertEqual(out.first?.primaryLayerId, brunch.id, "place layer wins over trail for styling")
    }

    func testHiddenTrailHidesItsEndpoints() {
        let hiddenTrail = LayerLite(id: UUID(), name: "Off", isVisible: false, kind: .waypointPath)
        let end = place("end", in: [hiddenTrail.id], endpoint: true)
        XCTAssertTrue(LayerMath.filter([end], layers: [brunch, hiddenTrail], mode: .union).isEmpty)
    }

    // MARK: - Legend

    func testLegendLabelOrderedBySortOrderAndCount() {
        // Membership arrays deliberately list favorites before brunch so the
        // label order must come from sortOrder, not input order.
        let places = [
            place("1", in: [favorites.id, brunch.id]),
            place("2", in: [favorites.id, brunch.id]),
            place("3", in: [favorites.id, brunch.id]),
            place("4", in: [coffee.id, favorites.id, brunch.id]),
            place("5", in: [brunch.id]),                      // matchCount 1: never in legend
            place("6", in: [trail.id], endpoint: true),       // trail only: never in legend
        ]
        let matched = LayerMath.filter(places, layers: layers, mode: .union)
        let legend = LayerMath.intersectionLegend(matched, layers: layers)

        XCTAssertEqual(legend.map(\.label), ["Brunch ∩ Favorites", "Brunch ∩ Favorites ∩ Coffee"])
        XCTAssertEqual(legend.map(\.count), [3, 1])
        XCTAssertEqual(legend[0].layerIds, [brunch.id, favorites.id])
        XCTAssertEqual(legend[1].layerIds, [brunch.id, favorites.id, coffee.id])
    }

    func testLegendRespectsLimit() {
        let places = [
            place("1", in: [brunch.id, favorites.id]),
            place("2", in: [brunch.id, coffee.id]),
            place("3", in: [favorites.id, coffee.id]),
            place("4", in: [favorites.id, coffee.id]),
        ]
        let matched = LayerMath.filter(places, layers: layers, mode: .union)
        XCTAssertEqual(LayerMath.intersectionLegend(matched, layers: layers).count, 3)
        let top1 = LayerMath.intersectionLegend(matched, layers: layers, limit: 1)
        XCTAssertEqual(top1.map(\.label), ["Favorites ∩ Coffee"])
        XCTAssertEqual(top1.first?.count, 2)
        XCTAssertTrue(LayerMath.intersectionLegend(matched, layers: layers, limit: 0).isEmpty)
    }

    func testLegendIgnoresHiddenLayerMemberships() {
        let p = place("p", in: [brunch.id, hidden.id])
        let matched = LayerMath.filter([p], layers: layers, mode: .union)
        XCTAssertTrue(LayerMath.intersectionLegend(matched, layers: layers).isEmpty)
    }
}
