import XCTest
@testable import CustomMapApp

final class LayerMathTests: XCTestCase {

    // Fixtures: three tags, one visible trail group, one hidden trail group,
    // and a tag whose `isVisible` is false (which no longer filters anything).
    let brunch = LayerLite(id: UUID(), name: "Brunch", sortOrder: 0)
    let favorites = LayerLite(id: UUID(), name: "Favorites", sortOrder: 1)
    let coffee = LayerLite(id: UUID(), name: "Coffee", sortOrder: 2)
    let trail = LayerLite(id: UUID(), name: "Canal Walk", kind: .waypointPath, sortOrder: 3)
    let hiddenTrail = LayerLite(id: UUID(), name: "Off Walk", isVisible: false, kind: .waypointPath, sortOrder: 4)
    let oldHidden = LayerLite(id: UUID(), name: "Old hidden", isVisible: false, sortOrder: 5)

    var layers: [LayerLite] { [brunch, favorites, coffee, trail, hiddenTrail, oldHidden] }

    func place(_ name: String, in layerIds: [UUID], endpoint: Bool = false) -> PlaceLite {
        PlaceLite(id: UUID(), name: name, layerIds: layerIds, isEndpoint: endpoint)
    }

    func filter(_ ids: [UUID] = [], _ match: TagMatch = .any,
                showPlaces: Bool = true, showTrails: Bool = true) -> PlaceFilter {
        PlaceFilter(tagIds: Set(ids), match: match, showPlaces: showPlaces, showTrails: showTrails)
    }

    // MARK: - Sets

    func testTagAndTrailSetsSplitByKind() {
        XCTAssertEqual(LayerMath.tagIds(layers), [brunch.id, favorites.id, coffee.id, oldHidden.id])
        XCTAssertEqual(LayerMath.trailGroupIds(layers), [trail.id, hiddenTrail.id])
        XCTAssertEqual(LayerMath.visibleTrailLayerIds(layers), [trail.id])
        XCTAssertTrue(LayerMath.visibleTrailLayerIds(layers, showTrails: false).isEmpty)
    }

    func testMatchCountCountsOnlyGivenIds() {
        let p = place("x", in: [brunch.id, coffee.id, trail.id])
        XCTAssertEqual(LayerMath.matchCount(p, visible: [brunch.id]), 1)
        XCTAssertEqual(LayerMath.matchCount(p, visible: [brunch.id, coffee.id]), 2)
        XCTAssertEqual(LayerMath.matchCount(p, visible: []), 0)
    }

    // MARK: - Empty selection

    func testEmptySelectionShowsEveryPlaceIncludingUntaggedAndHiddenTags() {
        let inBrunch = place("brunch", in: [brunch.id])
        let inOldHidden = place("old hidden", in: [oldHidden.id])
        let untagged = place("untagged", in: [])
        let both = place("both", in: [favorites.id, brunch.id])

        let out = LayerMath.filter([inBrunch, inOldHidden, untagged, both], layers: layers, filter: filter())
        XCTAssertEqual(out.map(\.id), [inBrunch.id, inOldHidden.id, untagged.id, both.id],
                       "order preserved; a tag's isVisible no longer filters")
        XCTAssertEqual(out.map(\.matchCount), [0, 0, 0, 0], "matchCount counts selected tags only")
        XCTAssertFalse(out.contains(where: \.showsOverlap))
    }

    // MARK: - Any / All

    func testAnyShowsPlacesWithAtLeastOneSelectedTag() {
        let inBrunch = place("brunch", in: [brunch.id])
        let inCoffee = place("coffee", in: [coffee.id])
        let shared = place("shared", in: [brunch.id, favorites.id])
        let untagged = place("untagged", in: [])

        let out = LayerMath.filter([inBrunch, inCoffee, shared, untagged], layers: layers,
                                   filter: filter([brunch.id, favorites.id], .any))
        XCTAssertEqual(out.map(\.id), [inBrunch.id, shared.id], "untagged hidden while a selection exists")
        XCTAssertEqual(out.map(\.matchCount), [1, 2])
    }

    func testAllShowsOnlyPlacesWithEverySelectedTag() {
        let twoOfThree = place("two", in: [brunch.id, favorites.id])
        let all = place("all", in: [brunch.id, favorites.id, coffee.id])
        let untagged = place("untagged", in: [])
        let out = LayerMath.filter([twoOfThree, all, untagged], layers: layers,
                                   filter: filter([brunch.id, favorites.id, coffee.id], .all))
        XCTAssertEqual(out.map(\.id), [all.id])
        XCTAssertEqual(out.first?.matchCount, 3)
    }

    func testAllWithSingleTagEqualsAny() {
        let a = place("a", in: [brunch.id])
        let b = place("b", in: [coffee.id])
        let any = LayerMath.filter([a, b], layers: layers, filter: filter([brunch.id], .any)).map(\.id)
        let all = LayerMath.filter([a, b], layers: layers, filter: filter([brunch.id], .all)).map(\.id)
        XCTAssertEqual(any, [a.id])
        XCTAssertEqual(all, any)
    }

    func testDeletedTagIdsInSelectionAreIgnored() {
        let a = place("a", in: [brunch.id])
        let untagged = place("u", in: [])
        let stale = UUID()
        let out = LayerMath.filter([a, untagged], layers: layers, filter: filter([stale], .all))
        XCTAssertEqual(out.map(\.id), [a.id, untagged.id], "a selection of only deleted tags shows everything")
        let mixed = LayerMath.filter([a, untagged], layers: layers, filter: filter([stale, brunch.id], .all))
        XCTAssertEqual(mixed.map(\.id), [a.id], "a deleted id never makes All impossible")
    }

    // MARK: - Overlap ring

    func testOverlapRingOnlyInAnyModeWithTwoOrMoreSelectedTags() {
        let shared = place("shared", in: [brunch.id, favorites.id])
        let single = place("single", in: [brunch.id, coffee.id])
        let ids = [brunch.id, favorites.id]

        let any = LayerMath.filter([shared, single], layers: layers, filter: filter(ids, .any))
        XCTAssertEqual(any.map(\.showsOverlap), [true, false], "coffee is not selected, so single matches 1")

        let all = LayerMath.filter([shared, single], layers: layers, filter: filter(ids, .all))
        XCTAssertEqual(all.map(\.id), [shared.id])
        XCTAssertEqual(all.first?.matchCount, 2)
        XCTAssertEqual(all.first?.showsOverlap, false, "every place matches every tag in All: no ring")

        let none = LayerMath.filter([shared], layers: layers, filter: filter())
        XCTAssertEqual(none.first?.showsOverlap, false, "no selection: no ring")
    }

    // MARK: - Pin tag

    func testPinIsLowestSortOrderSelectedTag() {
        let p = place("p", in: [coffee.id, favorites.id, brunch.id])
        let out = LayerMath.filter([p], layers: layers, filter: filter([coffee.id, favorites.id], .any))
        XCTAssertEqual(out.first?.pinLayerId, favorites.id, "brunch is lower but not selected")
        XCTAssertEqual(LayerMath.pinTag(for: p, layers: layers, filter: filter([coffee.id], .any)), coffee.id)
    }

    func testPinWithNoSelectionIsLowestSortOrderTag() {
        let p = place("p", in: [coffee.id, favorites.id, trail.id])
        let out = LayerMath.filter([p], layers: layers, filter: filter())
        XCTAssertEqual(out.first?.pinLayerId, favorites.id, "a tag wins over a trail group")
        XCTAssertEqual(LayerMath.pinTag(for: p, layers: layers, filter: filter()), favorites.id)
    }

    func testPinOfUntaggedPlaceIsNil() {
        let p = place("p", in: [])
        XCTAssertNil(LayerMath.filter([p], layers: layers, filter: filter()).first?.pinLayerId)
    }

    // MARK: - Places / Trails switches

    func testShowPlacesOffHidesEverythingIncludingEndpoints() {
        let a = place("a", in: [brunch.id])
        let end = place("end", in: [trail.id], endpoint: true)
        XCTAssertTrue(LayerMath.filter([a, end], layers: layers, filter: filter(showPlaces: false)).isEmpty)
    }

    func testShowTrailsOffHidesTrailOnlyEndpointsButNotTaggedOnes() {
        let end = place("end", in: [trail.id], endpoint: true)
        let taggedEnd = place("tagged end", in: [trail.id, brunch.id], endpoint: true)
        let out = LayerMath.filter([end, taggedEnd], layers: layers, filter: filter(showTrails: false))
        XCTAssertEqual(out.map(\.id), [taggedEnd.id])
    }

    // MARK: - Trail rule

    func testTrailOnlyNonEndpointHiddenEndpointShownInEveryMode() {
        let mid = place("mid", in: [trail.id], endpoint: false)
        let end = place("end", in: [trail.id], endpoint: true)

        for f in [filter(), filter([brunch.id], .any), filter([brunch.id, coffee.id], .all)] {
            let out = LayerMath.filter([mid, end], layers: layers, filter: f)
            XCTAssertEqual(out.map(\.id), [end.id], "filter \(f)")
            XCTAssertEqual(out.first?.matchCount, 0)
            XCTAssertEqual(out.first?.pinLayerId, trail.id)
        }
    }

    func testTrailMidpointWithATagIsASavedPlace() {
        let mid = place("mid", in: [trail.id, brunch.id], endpoint: false)
        let out = LayerMath.filter([mid], layers: layers, filter: filter([brunch.id]))
        XCTAssertEqual(out.map(\.id), [mid.id])
        XCTAssertEqual(out.first?.pinLayerId, brunch.id)
    }

    func testHiddenTrailGroupHidesItsEndpoints() {
        let end = place("end", in: [hiddenTrail.id], endpoint: true)
        XCTAssertTrue(LayerMath.filter([end], layers: layers, filter: filter()).isEmpty)
    }

    // MARK: - Matching count

    func testMatchingPlaceCountCountsTagMatchesOnly() {
        let places = [
            place("all", in: [brunch.id, favorites.id]),
            place("one", in: [brunch.id]),
            place("untagged", in: []),
            place("end", in: [trail.id], endpoint: true),
        ]
        XCTAssertEqual(LayerMath.matchingPlaceCount(places, layers: layers, filter: filter()), 3,
                       "no selection: every saved place, never trail points")
        XCTAssertEqual(LayerMath.matchingPlaceCount(places, layers: layers,
                                                    filter: filter([brunch.id, favorites.id], .any)), 2)
        XCTAssertEqual(LayerMath.matchingPlaceCount(places, layers: layers,
                                                    filter: filter([brunch.id, favorites.id], .all)), 1)
        XCTAssertEqual(LayerMath.matchingPlaceCount(places, layers: layers,
                                                    filter: filter([brunch.id], .any, showPlaces: false)), 2,
                       "the count ignores the Places switch")
    }
}
