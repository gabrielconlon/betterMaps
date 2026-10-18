import XCTest
@testable import CustomMapApp

/// The bundled `Resources/Transit/*.json` decode and look sane.
final class TransitBundleDecodingTests: XCTestCase {
    /// `--bbox` default in scripts/build_transit_bundle.py.
    let bbox = GeoBox(minLat: 53.15, maxLat: 53.65, minLon: -6.65, maxLon: -5.95)

    private func loadBundle() throws -> TransitBundle {
        let urls = try XCTUnwrap(TransitBundle.URLs(bundle: Bundle(for: TransitLayerStore.self)),
                                 "transit JSON missing from the app bundle")
        return try TransitBundle.load(urls)
    }

    func testEveryStopIsInsideTheBBox() throws {
        let stops = try loadBundle().stops
        XCTAssertGreaterThan(stops.count, 1000)
        let outside = stops.filter { !bbox.contains(lat: $0.latitude, lon: $0.longitude) }
        XCTAssertTrue(outside.isEmpty, "outside bbox: \(outside.prefix(5).map(\.id))")
    }

    func testEveryKindIsPresent() throws {
        let stops = try loadBundle().stops
        for kind in TransitLayerKind.allCases {
            XCTAssertFalse(stops.filter { $0.kind == kind }.isEmpty, "no \(kind) stops")
        }
        XCTAssertTrue(stops.filter { $0.kind == .luas }.allSatisfy { $0.line == "red" || $0.line == "green" })
        XCTAssertTrue(stops.contains { $0.kinds.count > 1 }, "multi-kind stops (Connolly) carry `kinds`")
    }

    func testNoDuplicateIds() throws {
        let stops = try loadBundle().stops
        let allIds = stops.flatMap(\.allIds)
        XCTAssertEqual(Set(allIds).count, allIds.count, "stop ids and altIds are unique")
    }

    func testLinesAndRoutes() throws {
        let bundle = try loadBundle()
        XCTAssertTrue(bundle.lines.allSatisfy { $0.coordinates.count >= 2 })
        let red = try XCTUnwrap(bundle.lines.first { $0.id == "luas-red" })
        XCTAssertEqual(red.kind, .luas)
        XCTAssertEqual(red.line, "red")
        XCTAssertTrue(bundle.lines.contains { $0.kind == .dart })
        XCTAssertTrue(bundle.lines.contains { $0.kind == .rail })
        XCTAssertGreaterThan(bundle.routes.count, 100)
        XCTAssertEqual(Set(bundle.routes.map(\.id)).count, bundle.routes.count)
        XCTAssertTrue(bundle.routes.contains { $0.short == "39A" && $0.kind == .bus })
    }

    func testStopRoundTripsThroughJSON() throws {
        let stop = TransitStop(id: "A", name: "Abbey St.", latitude: 53.3485, longitude: -6.25845,
                               kind: .luas, line: "red", altIds: ["B"])
        let decoded = try JSONDecoder().decode(TransitStop.self, from: JSONEncoder().encode(stop))
        XCTAssertEqual(decoded, stop)
        XCTAssertEqual(decoded.kinds, [.luas])
    }

    @MainActor
    func testStoreLoadsOnce() async throws {
        let store = TransitLayerStore(bundle: Bundle(for: TransitLayerStore.self))
        XCTAssertFalse(store.isLoaded)
        let start = Date()
        async let first: Void = store.loadIfNeeded()
        async let second: Void = store.loadIfNeeded()
        _ = await (first, second)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(store.isLoaded)
        XCTAssertGreaterThan(store.stops.count, 1000)
        XCTAssertFalse(store.lines.isEmpty)
        XCTAssertFalse(store.routes.isEmpty)
        XCTAssertLessThan(elapsed, 2, "bundle decode should be well under a second")
    }
}
