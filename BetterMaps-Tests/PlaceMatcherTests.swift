import XCTest
import CoreLocation
@testable import CustomMapApp

final class PlaceMatcherTests: XCTestCase {
    /// Roughly 1 m of latitude in degrees.
    let metre = 1.0 / 111_195
    let origin = CLLocationCoordinate2D(latitude: 53.3438, longitude: -6.2546)

    func lite(_ name: String, north metres: Double, layers: [UUID] = []) -> PlaceLite {
        PlaceLite(id: UUID(), name: name, latitude: origin.latitude + metres * metre,
                  longitude: origin.longitude, layerIds: layers)
    }

    func testSameNameWithin30MetresMatches() {
        let cafe = lite("Brother Hubbard", north: 25)
        XCTAssertEqual(PlaceMatcher.match(name: "Brother Hubbard", coordinate: origin, among: [cafe]), cafe.id)
    }

    func testSameNameBeyond30MetresDoesNotMatch() {
        let cafe = lite("Brother Hubbard", north: 40)
        XCTAssertNil(PlaceMatcher.match(name: "Brother Hubbard", coordinate: origin, among: [cafe]))
    }

    func testNamesAreNormalised() {
        let cafe = lite("Café  Nero!", north: 10)
        XCTAssertEqual(PlaceMatcher.match(name: "cafe nero", coordinate: origin, among: [cafe]), cafe.id)
        XCTAssertEqual(PlaceMatcher.normalisedName("Fish & Chips"), PlaceMatcher.normalisedName("fish and chips"))
    }

    func testDifferentNameMatchesOnlyWithin8Metres() {
        let near = lite("Dropped Pin", north: 6)
        let far = lite("Somewhere Else", north: 15)
        XCTAssertEqual(PlaceMatcher.match(name: "Brunch spot", coordinate: origin, among: [near]), near.id)
        XCTAssertNil(PlaceMatcher.match(name: "Brunch spot", coordinate: origin, among: [far]))
    }

    func testEmptyNameUsesOnlyTheDistanceRule() {
        let p = lite("", north: 20)
        XCTAssertNil(PlaceMatcher.match(name: "", coordinate: origin, among: [p]), "two blank names are not a name match")
        let close = lite("", north: 3)
        XCTAssertEqual(PlaceMatcher.match(name: "", coordinate: origin, among: [close]), close.id)
    }

    func testClosestMatchWins() {
        let a = lite("Kaph", north: 20)
        let b = lite("Kaph", north: 5)
        XCTAssertEqual(PlaceMatcher.match(name: "Kaph", coordinate: origin, among: [a, b]), b.id)
    }

    func testCandidatesExcludeTrailWaypoints() {
        let brunch = LayerLite(id: UUID(), name: "Brunch")
        let trail = LayerLite(id: UUID(), name: "Canal", kind: .waypointPath)
        let saved = lite("Saved", north: 0, layers: [brunch.id])
        let waypoint = lite("Waypoint", north: 0, layers: [trail.id])
        let both = lite("Both", north: 0, layers: [brunch.id, trail.id])
        let ids = PlaceMatcher.candidates([saved, waypoint, both], layers: [brunch, trail]).map(\.id)
        XCTAssertEqual(ids, [saved.id])
    }

    func testDistanceIsRoughlyMetres() {
        let d = PlaceMatcher.distanceMeters(origin.latitude, origin.longitude, origin.latitude + 100 * metre, origin.longitude)
        XCTAssertEqual(d, 100, accuracy: 0.5)
    }

    func testSavedMessage() {
        XCTAssertEqual(PlaceFormView.savedMessage(layerNames: ["Brunch"]), "Saved to Brunch")
        XCTAssertEqual(PlaceFormView.savedMessage(layerNames: ["Brunch", "Favourites"]), "Saved to Brunch + Favourites")
        XCTAssertEqual(PlaceFormView.savedMessage(layerNames: ["A", "B", "C"]), "Saved to 3 layers")
        XCTAssertEqual(PlaceFormView.savedMessage(layerNames: []), "Place saved")
    }
}
