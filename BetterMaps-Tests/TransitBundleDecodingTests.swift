import XCTest
import CoreLocation
@testable import CustomMapApp

/// The bundled `Resources/Transit/*.json` decode and look sane.
final class TransitBundleDecodingTests: XCTestCase {
    /// `--bbox` default in scripts/build_transit_bundle.py (the island of
    /// Ireland since 2026-10-25).
    let bbox = GeoBox(minLat: 51.3, maxLat: 55.5, minLon: -10.8, maxLon: -5.3)
    /// The Dublin-only box the bundle used before it went national.
    let dublin = GeoBox(minLat: 53.15, maxLat: 53.65, minLon: -6.65, maxLon: -5.95)

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

    /// Guards against a rebuild quietly falling back to the Dublin box:
    /// intercity rail and regional buses must reach well beyond it.
    func testCoverageIsNationalNotDublinOnly() throws {
        let stops = try loadBundle().stops
        let beyondDublin = stops.filter { !dublin.contains(lat: $0.latitude, lon: $0.longitude) }
        XCTAssertGreaterThan(beyondDublin.filter { $0.kind == .rail }.count, 50, "intercity rail stations")
        XCTAssertGreaterThan(beyondDublin.filter { $0.kind == .bus }.count, 1000, "regional bus stops")
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

    func testLineIdsAreUnique() throws {
        let ids = try loadBundle().lines.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "line ids are ForEach identities and must be unique")
    }

    /// Mirrors the coverage gate in scripts/build_transit_bundle.py: no DART /
    /// rail / Luas station may sit away from the drawn track (the DART used to
    /// stop at Grand Canal Dock, and Luas / rail branches were missing).
    func testEveryRailStationIsOnALineOfItsKind() throws {
        let bundle = try loadBundle()
        let maxMetres = 150.0
        var worst: [String: Double] = [:]
        var offenders: [String] = []
        for stop in bundle.stops where [TransitLayerKind.dart, .rail, .luas].contains(stop.kind) {
            let lines = bundle.lines.filter {
                $0.kind == stop.kind && (stop.kind != .luas || stop.line == nil || $0.line == stop.line)
            }
            let p = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
            var best = Double.infinity
            for line in lines {
                for (a, b) in zip(line.coordinates, line.coordinates.dropFirst()) {
                    best = min(best, Self.distanceMetres(p, segment: a, b))
                }
            }
            let key = stop.kind == .luas ? "luas-\(stop.line ?? "?")" : "\(stop.kind)"
            worst[key] = max(worst[key] ?? 0, best)
            if best > maxMetres { offenders.append("\(stop.name) (\(key)) \(Int(best)) m") }
        }
        XCTAssertTrue(offenders.isEmpty, "stations off their line: \(offenders)")
        for key in ["dart", "rail", "luas-red", "luas-green"] {
            XCTAssertNotNil(worst[key], "no \(key) stations checked")
        }
    }

    /// Point-to-segment distance on a local equirectangular projection; plenty
    /// accurate over the few km a Dublin segment spans.
    private static func distanceMetres(_ p: CLLocationCoordinate2D, segment a: CLLocationCoordinate2D,
                                       _ b: CLLocationCoordinate2D) -> Double {
        let mPerDeg = 6_371_000.0 * Double.pi / 180
        let cosLat = cos(p.latitude * Double.pi / 180)
        let ax = (a.longitude - p.longitude) * cosLat * mPerDeg, ay = (a.latitude - p.latitude) * mPerDeg
        let bx = (b.longitude - p.longitude) * cosLat * mPerDeg, by = (b.latitude - p.latitude) * mPerDeg
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
        return hypot(ax + t * dx, ay + t * dy)
    }

    func testStopRoundTripsThroughJSON() throws {
        let stop = TransitStop(id: "A", name: "Abbey St.", latitude: 53.3485, longitude: -6.25845,
                               kind: .luas, line: "red", altIds: ["B"])
        let decoded = try JSONDecoder().decode(TransitStop.self, from: JSONEncoder().encode(stop))
        XCTAssertEqual(decoded, stop)
        XCTAssertEqual(decoded.kinds, [.luas])
    }

    /// `brg` / `to` from the builder (see the gtfs_mini row in scripts/README.md).
    func testBusStopHeadingDecodes() throws {
        let json = #"{"id":"8220DB000002","name":"Parnell Square","lat":53.3532,"lon":-6.2634,"kind":"bus","code":"2","brg":153,"to":"UCD"}"#
        let stop = try JSONDecoder().decode(TransitStop.self, from: Data(json.utf8))
        XCTAssertEqual(stop.heading, 153)
        XCTAssertEqual(stop.toward, "UCD")
        XCTAssertEqual(stop.headingName, "south-east")
        XCTAssertEqual(try JSONDecoder().decode(TransitStop.self, from: JSONEncoder().encode(stop)), stop)

        let terminus = try JSONDecoder().decode(TransitStop.self, from: Data(
            #"{"id":"8220DB000004","name":"Eden Quay","lat":53.3479,"lon":-6.2562,"kind":"bus","code":"4"}"#.utf8))
        XCTAssertNil(terminus.heading)
        XCTAssertNil(terminus.headingName)
    }

    /// The 2026-10-25 national build gives 12,850 of 13,897 bus stops a
    /// heading; the rest are terminus loops or stops where routes split.
    func testMostBusStopsHaveAHeading() throws {
        let bus = try loadBundle().stops.filter { $0.kind == .bus }
        let withHeading = bus.filter { $0.heading != nil }
        XCTAssertGreaterThan(Double(withHeading.count) / Double(bus.count), 0.8)
        XCTAssertTrue(withHeading.allSatisfy { (0..<360).contains($0.heading!) })
        XCTAssertTrue(try loadBundle().stops.filter { $0.kind != .bus }.allSatisfy { $0.heading == nil })
    }

    func testHeadingNamesRoundToTheNearestEighth() {
        func name(_ h: Int) -> String? {
            TransitStop(id: "x", name: "x", latitude: 53, longitude: -6, kind: .bus, heading: h).headingName
        }
        XCTAssertEqual(name(0), "north")
        XCTAssertEqual(name(359), "north")
        XCTAssertEqual(name(22), "north")
        XCTAssertEqual(name(23), "north-east")
        XCTAssertEqual(name(90), "east")
        XCTAssertEqual(name(200), "south")
        XCTAssertEqual(name(292), "west")
        XCTAssertEqual(name(293), "north-west")
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
