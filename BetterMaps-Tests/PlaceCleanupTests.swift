import XCTest
import SwiftData
@testable import CustomMapApp

@MainActor
final class PlaceCleanupTests: XCTestCase {

    func testDetachDeletesOnlyPlacesLeftWithNoLayers() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let coffee = Layer(name: "Coffee", kind: .places)
        let brunch = Layer(name: "Brunch", kind: .places)
        context.insert(coffee)
        context.insert(brunch)
        let shared = Place(name: "Two Boys Brew")
        let solo = Place(name: "3fe")
        context.insert(shared)
        context.insert(solo)
        coffee.places = [shared, solo]
        brunch.places = [shared]
        try context.save()

        PlaceCleanup.detach(shared, from: coffee, in: context)
        PlaceCleanup.detach(solo, from: coffee, in: context)
        try context.save()

        let left = try context.fetch(FetchDescriptor<Place>())
        XCTAssertEqual(left.map(\.id), [shared.id], "the place still in Brunch survives")
        XCTAssertEqual(coffee.places?.count ?? 0, 0)
        XCTAssertEqual(brunch.places?.map(\.id), [shared.id])
    }

    func testDeleteLayerKeepsSharedPlacesAndRemovesTheRest() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let coffee = Layer(name: "Coffee", kind: .places)
        let brunch = Layer(name: "Brunch", kind: .places)
        context.insert(coffee)
        context.insert(brunch)
        let shared = Place(name: "Two Boys Brew")
        let solo = Place(name: "3fe")
        context.insert(shared)
        context.insert(solo)
        coffee.places = [shared, solo]
        brunch.places = [shared]
        try context.save()

        PlaceCleanup.deleteLayer(coffee, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Layer>()).map(\.id), [brunch.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Place>()).map(\.id), [shared.id])
        XCTAssertEqual(brunch.places?.map(\.id), [shared.id])
    }

    func testDeleteTrailLayerDeletesTrailsAndTheirPoints() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let walks = Layer(name: "Walks", kind: .waypointPath)
        let favourites = Layer(name: "Favourites", kind: .places)
        context.insert(walks)
        context.insert(favourites)
        var draft = TrailDraft(name: "Canal")
        draft.points = [TrailPoint(coordinate: TestCoords.a), TrailPoint(coordinate: TestCoords.b)]
        let trail = TrailCommitter.commit(draft, geometry: nil, to: walks, trail: nil, in: context)
        // One trail point was also saved as a favourite.
        let point = try XCTUnwrap(walks.places?.first)
        favourites.places = [point]
        try context.save()
        XCTAssertEqual(trail.layer?.id, walks.id)

        PlaceCleanup.deleteLayer(walks, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Place>()).map(\.id), [point.id])
    }
}
