import XCTest
import MapKit
@testable import CustomMapApp

/// Tapping one of Apple's own transit icons opens our stop for it. These pin
/// the matching with the real Connolly / Busáras stops from the bundle.
@MainActor
final class TransitPOIMatchTests: XCTestCase {
    private let luasConnolly = TransitStop(id: "8220GA00423", name: "Connolly", latitude: 53.35093, longitude: -6.24985,
                                           kind: .luas, line: "red")
    private let railConnolly = TransitStop(id: "8220IR0007", name: "Connolly", latitude: 53.35125, longitude: -6.2497,
                                           kind: .dart, kinds: [.dart, .rail])
    private let luasBusaras = TransitStop(id: "8220GA00420", name: "Busáras", latitude: 53.35005, longitude: -6.2516,
                                          kind: .luas, line: "red")
    private let busConnolly = TransitStop(id: "8220DB000497", name: "Connolly Stn", latitude: 53.35053, longitude: -6.25069,
                                          kind: .bus)

    private func store() -> TransitLayerStore {
        let store = TransitLayerStore()
        store.apply(TransitBundle(stops: [luasConnolly, railConnolly, luasBusaras, busConnolly], lines: [], routes: []))
        return store
    }

    /// Apple's "Connolly Station" icon sits nearer the Busáras and Connolly
    /// Luas stops than the station itself; it must open the DART/rail stop.
    func testConnollyStationOpensRailStopNotNearerLuas() {
        let apple = CLLocationCoordinate2D(latitude: 53.3505, longitude: -6.2508)
        XCTAssertEqual(store().nearestStop(to: apple)?.id, luasBusaras.id, "precondition: Busáras is nearest")
        XCTAssertEqual(store().nearestStop(to: apple, title: "Connolly Station")?.id, railConnolly.id)
    }

    func testLuasTitlePrefersLuasStop() {
        let apple = CLLocationCoordinate2D(latitude: 53.3512, longitude: -6.2497)
        XCTAssertEqual(store().nearestStop(to: apple, title: "Connolly Luas Stop")?.id, luasConnolly.id)
    }

    func testDiacriticsFolded() {
        let apple = CLLocationCoordinate2D(latitude: 53.3510, longitude: -6.2498)
        XCTAssertEqual(store().nearestStop(to: apple, title: "Busaras")?.id, luasBusaras.id)
    }

    func testUnmatchedTitleFallsBackToNearest() {
        let apple = CLLocationCoordinate2D(latitude: 53.3505, longitude: -6.2508)
        XCTAssertEqual(store().nearestStop(to: apple, title: "Amiens Street")?.id, luasBusaras.id)
    }

    func testStnAbbreviationMatchesStation() {
        XCTAssertEqual(TransitLayerStore.bestMatch([luasBusaras, busConnolly], title: "Connolly Station")?.id,
                       busConnolly.id)
    }

    func testNothingInRangeIsNil() {
        let galway = CLLocationCoordinate2D(latitude: 53.2707, longitude: -9.0568)
        XCTAssertNil(store().nearestStop(to: galway, title: "Ceannt Station"))
    }
}
