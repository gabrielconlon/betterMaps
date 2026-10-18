import XCTest
import SwiftData
@testable import CustomMapApp

@MainActor
final class LayerFilterViewModelTests: XCTestCase {

    /// A fresh, empty UserDefaults suite that is wiped when the test ends.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "LayerFilterViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testDefaultsToUnionWhenNothingStored() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(LayerFilterViewModel(defaults: defaults).filterMode, .union)
    }

    func testFilterModePersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        let first = LayerFilterViewModel(defaults: defaults)
        first.filterMode = .intersection
        XCTAssertEqual(defaults.string(forKey: LayerFilterViewModel.filterModeDefaultsKey),
                       FilterMode.intersection.rawValue)

        let second = LayerFilterViewModel(defaults: defaults)
        XCTAssertEqual(second.filterMode, .intersection)

        second.filterMode = .union
        XCTAssertEqual(LayerFilterViewModel(defaults: defaults).filterMode, .union)
    }

    func testGarbageStoredValueFallsBackToUnion() throws {
        let defaults = try makeDefaults()
        defaults.set("nonsense", forKey: LayerFilterViewModel.filterModeDefaultsKey)
        XCTAssertEqual(LayerFilterViewModel(defaults: defaults).filterMode, .union)
    }

    /// The existing `filteredPlaces(allPlaces:allLayers:)` entry point must
    /// now ignore trail layers in intersection mode (the bug this phase fixes).
    func testFilteredPlacesIgnoresTrailLayerInIntersection() throws {
        let defaults = try makeDefaults()
        let container = try makeTestContainer()
        let context = container.mainContext

        let brunch = Layer(name: "Brunch", sortOrder: 0)
        let favorites = Layer(name: "Favorites", sortOrder: 1)
        let trailLayer = Layer(name: "Walk", sortOrder: 2, kind: .waypointPath)
        for l in [brunch, favorites, trailLayer] { context.insert(l) }

        let shared = Place(name: "Shared", latitude: 53.34, longitude: -6.26)
        let brunchOnly = Place(name: "Brunch only", latitude: 53.34, longitude: -6.25)
        let waypointMid = Place(name: "Mid", latitude: 53.35, longitude: -6.25)
        let waypointEnd = Place(name: "End", latitude: 53.35, longitude: -6.24)
        waypointEnd.isWaypointEndpoint = true
        for p in [shared, brunchOnly, waypointMid, waypointEnd] { context.insert(p) }

        shared.layers = [brunch, favorites]
        brunchOnly.layers = [brunch]
        waypointMid.layers = [trailLayer]
        waypointEnd.layers = [trailLayer]

        let vm = LayerFilterViewModel(defaults: defaults)
        let all = [shared, brunchOnly, waypointMid, waypointEnd]
        let layers = [brunch, favorites, trailLayer]

        vm.filterMode = .intersection
        XCTAssertEqual(vm.filteredPlaces(allPlaces: all, allLayers: layers).map(\.id),
                       [shared.id, waypointEnd.id])

        vm.filterMode = .union
        XCTAssertEqual(vm.filteredPlaces(allPlaces: all, allLayers: layers).map(\.id),
                       [shared.id, brunchOnly.id, waypointEnd.id])

        let matched = vm.matchedPlaces(allPlaces: all, allLayers: layers)
        XCTAssertEqual(matched.first?.primaryLayerId, brunch.id)
        XCTAssertEqual(matched.first?.matchCount, 2)
    }
}
