import XCTest
import CoreLocation
@testable import CustomMapApp

@MainActor
final class RecentSearchTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    private let heuston = DirectionsEndpoint(name: "Heuston", coordinate: CLLocationCoordinate2D(latitude: 53.3464, longitude: -6.2923))
    private let dunLaoghaire = DirectionsEndpoint(name: "Dún Laoghaire", coordinate: CLLocationCoordinate2D(latitude: 53.2938, longitude: -6.1353))

    override func setUp() async throws {
        suiteName = "RecentSearchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func poi(_ name: String, lat: Double = 53.34, lon: Double = -6.26) -> RecentSearch {
        RecentSearch(kind: .poi, name: name, subtitle: nil, latitude: lat, longitude: lon)
    }

    func testNewestFirstAndRepeatMovesToTop() {
        var list: [RecentSearch] = []
        list = RecentSearch.inserting(poi("Café"), into: list)
        list = RecentSearch.inserting(poi("Library"), into: list)
        list = RecentSearch.inserting(poi("Café", lat: 53.34001), into: list)
        XCTAssertEqual(list.map(\.name), ["Café", "Library"])
    }

    func testSameNameFarAwayIsADifferentPlace() {
        var list = RecentSearch.inserting(poi("Spar"), into: [])
        list = RecentSearch.inserting(poi("Spar", lat: 53.30), into: list)
        XCTAssertEqual(list.count, 2)
    }

    func testListIsTrimmed() {
        var list: [RecentSearch] = []
        for i in 0..<30 { list = RecentSearch.inserting(poi("P\(i)", lat: 53 + Double(i) / 100), into: list, limit: 25) }
        XCTAssertEqual(list.count, 25)
        XCTAssertEqual(list.first?.name, "P29")
    }

    func testJourneyFromMyLocationMatchesWhereverTheFixWas() {
        let a = RecentSearch.journey(from: .userLocation(heuston.coordinate), to: dunLaoghaire)
        let b = RecentSearch.journey(from: .userLocation(CLLocationCoordinate2D(latitude: 53.4, longitude: -6.4)), to: dunLaoghaire)
        XCTAssertTrue(a.isSameSearch(as: b))
        let reversed = RecentSearch.journey(from: dunLaoghaire, to: heuston)
        let forward = RecentSearch.journey(from: heuston, to: dunLaoghaire)
        XCTAssertFalse(forward.isSameSearch(as: reversed))
    }

    func testJourneyIsNotAPlaceButAStopIs() {
        XCTAssertNil(RecentSearch.journey(from: heuston, to: dunLaoghaire).endpoint)
        let stop = RecentSearch(kind: .stop(id: "8220DB000001", kind: .bus, line: nil, code: "1"),
                                name: "Parnell Square", subtitle: nil, latitude: 53.35, longitude: -6.26)
        XCTAssertEqual(stop.endpoint?.name, "Parnell Square")
    }

    func testStorePersistsRemovesAndClears() {
        let store = RecentSearchStore(defaults: defaults)
        store.recordJourney(from: heuston, to: dunLaoghaire)
        store.record(poi("Café"))
        XCTAssertEqual(RecentSearchStore(defaults: defaults).items.map(\.name), ["Café", "Dún Laoghaire"])

        let reopened = RecentSearchStore(defaults: defaults)
        if case .journey(let origin, _) = reopened.items[1].kind {
            XCTAssertEqual(origin.endpoint, heuston)
        } else {
            XCTFail("expected a journey")
        }
        XCTAssertEqual(reopened.places.map(\.name), ["Café"])

        store.remove(store.items[0].id)
        XCTAssertEqual(RecentSearchStore(defaults: defaults).items.count, 1)
        store.clear()
        XCTAssertTrue(RecentSearchStore(defaults: defaults).items.isEmpty)
    }
}
