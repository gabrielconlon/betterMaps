import XCTest
@testable import CustomMapApp

final class SmartDefaultLayerTests: XCTestCase {

    private let brunch = UUID()
    private let favorites = UUID()
    private let hidden = UUID()
    private let walks = UUID()

    private func layers(brunchVisible: Bool = true, favoritesVisible: Bool = true) -> [LayerLite] {
        [
            LayerLite(id: walks, name: "Walks", isVisible: true, kind: .waypointPath, sortOrder: 0),
            LayerLite(id: hidden, name: "Hidden", isVisible: false, kind: .places, sortOrder: 1),
            LayerLite(id: favorites, name: "Favorites", isVisible: favoritesVisible, kind: .places, sortOrder: 2),
            LayerLite(id: brunch, name: "Brunch", isVisible: brunchVisible, kind: .places, sortOrder: 3),
        ]
    }

    func testLastUsedVisiblePlaceLayerWins() {
        XCTAssertEqual(SmartDefaultLayer.placeLayer(in: layers(), lastUsedLayerId: brunch), brunch)
    }

    func testHiddenLastUsedFallsBackToFirstVisiblePlaceLayer() {
        XCTAssertEqual(SmartDefaultLayer.placeLayer(in: layers(brunchVisible: false), lastUsedLayerId: brunch),
                       favorites)
    }

    func testTrailLayerIsNeverAPlaceDefault() {
        XCTAssertEqual(SmartDefaultLayer.placeLayer(in: layers(), lastUsedLayerId: walks), favorites)
    }

    func testUnknownOrMissingLastUsedUsesFirstVisibleBySortOrder() {
        XCTAssertEqual(SmartDefaultLayer.placeLayer(in: layers(), lastUsedLayerId: UUID()), favorites)
        XCTAssertEqual(SmartDefaultLayer.placeLayer(in: layers().reversed(), lastUsedLayerId: nil), favorites)
    }

    func testAllPlaceLayersHiddenUsesFirstPlaceLayer() {
        let all = layers(brunchVisible: false, favoritesVisible: false)
        XCTAssertEqual(SmartDefaultLayer.placeLayer(in: all, lastUsedLayerId: nil), hidden)
    }

    func testNoPlaceLayersMeansCreateFavorites() {
        let onlyTrails = [LayerLite(id: walks, name: "Walks", kind: .waypointPath)]
        XCTAssertNil(SmartDefaultLayer.placeLayer(in: onlyTrails, lastUsedLayerId: walks))
        XCTAssertNil(SmartDefaultLayer.placeLayer(in: [], lastUsedLayerId: nil))
    }

    func testTrailLayerChoice() {
        let second = UUID()
        let all = layers() + [LayerLite(id: second, name: "Hikes", isVisible: false, kind: .waypointPath, sortOrder: 9)]
        XCTAssertEqual(SmartDefaultLayer.trailLayer(in: all, lastTrailLayerId: second), second)
        XCTAssertEqual(SmartDefaultLayer.trailLayer(in: all, lastTrailLayerId: brunch), walks)
        XCTAssertEqual(SmartDefaultLayer.trailLayer(in: all, lastTrailLayerId: nil), walks)
        XCTAssertNil(SmartDefaultLayer.trailLayer(in: [], lastTrailLayerId: nil))
    }

    func testNextColorSkipsUsedColors() {
        let palette = ["#FF3B30", "#FF9500", "#FFCC00"]
        XCTAssertEqual(SmartDefaultLayer.nextColorHex(palette: palette, used: []), "#FF3B30")
        XCTAssertEqual(SmartDefaultLayer.nextColorHex(palette: palette, used: ["#ff3b30"]), "#FF9500")
        XCTAssertEqual(SmartDefaultLayer.nextColorHex(palette: palette, used: palette), "#FF3B30")
    }
}
