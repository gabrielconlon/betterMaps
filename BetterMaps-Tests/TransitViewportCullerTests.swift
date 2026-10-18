import XCTest
import MapKit
import Observation
@testable import CustomMapApp

/// Thread-safe flag for `withObservationTracking`'s `@Sendable` onChange.
final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class TransitViewportCullerTests: XCTestCase {
    let center = (lat: 53.3498, lon: -6.2603)

    func viewport(span: Double) -> GeoBox {
        GeoBox(minLat: center.lat - span / 2, maxLat: center.lat + span / 2,
               minLon: center.lon - span / 2, maxLon: center.lon + span / 2)
    }

    /// `count` stops of `kind` spread over a ±`radius`° square around the centre.
    func stops(_ kind: TransitLayerKind, count: Int, radius: Double, prefix: String) -> [TransitStop] {
        var rng = SeededGenerator(seed: UInt64(count) &+ UInt64(prefix.count))
        return (0..<count).map { i in
            makeStop(id: "\(prefix)\(i)", name: "\(prefix) \(i)",
                     lat: center.lat + Double.random(in: -radius...radius, using: &rng),
                     lon: center.lon + Double.random(in: -radius...radius, using: &rng),
                     type: kind)
        }
    }

    func testBusHiddenOnlyWhenCountryWide() {
        let all = stops(.bus, count: 50, radius: 0.01, prefix: "b") + stops(.luas, count: 5, radius: 0.01, prefix: "l")
        let grid = TransitSpatialGrid(stops: all)
        let enabled: Set<TransitLayerKind> = [.bus, .luas]

        let far = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 1.2), enabled: enabled)
        XCTAssertTrue(far.allSatisfy { $0.kind == .luas }, "no bus stops above a 1.0° span")
        XCTAssertEqual(far.count, 5, "Luas still shown country-wide")

        // City and regional zooms keep bus (the old 0.08° cut-off is gone).
        for span in [0.99, 0.5, 0.15, 0.08] {
            let near = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: span), enabled: enabled)
            XCTAssertEqual(near.filter { $0.kind == .luas }.count, 5, "span \(span)")
            XCTAssertFalse(near.filter { $0.kind == .bus }.isEmpty, "span \(span)")
        }
    }

    func testRailAlwaysShownAtEveryZoom() {
        let rail = stops(.rail, count: 10, radius: 0.004, prefix: "r")
            + stops(.dart, count: 10, radius: 0.004, prefix: "d")
            + stops(.luas, count: 10, radius: 0.004, prefix: "l")
        let bus = stops(.bus, count: 1500, radius: 0.004, prefix: "b")
        let grid = TransitSpatialGrid(stops: bus + rail)
        for span in [2.0, 1.2, 0.5, 0.1, 0.01] {
            let result = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: span),
                                                           enabled: Set(TransitLayerKind.allCases))
            XCTAssertEqual(result.filter { $0.kind != .bus }.count, 30, "every rail/DART/Luas stop survives at \(span)")
            // Rail-before-bus priority.
            XCTAssertTrue(result.prefix(30).allSatisfy { $0.kind != .bus })
        }
    }

    /// 20k bus stops over ±0.3°: dense enough that every sampling cell at
    /// city and regional zoom holds a stop.
    lazy var denseBus = stops(.bus, count: 20_000, radius: 0.3, prefix: "d")
    lazy var denseGrid = TransitSpatialGrid(stops: denseBus)

    func testBudgetsByZoom() {
        XCTAssertEqual(TransitViewportCuller.busBudgetCity, 220)
        XCTAssertEqual(TransitViewportCuller.busBudgetRegional, 120)
        func count(_ span: Double) -> Int {
            TransitViewportCuller.visibleStops(grid: denseGrid, viewport: viewport(span: span), enabled: [.bus]).count
        }
        XCTAssertEqual(count(1.2), 0, "no bus above a 1.0° span")
        XCTAssertEqual(count(0.5), 120, "span 0.3–1.0: up to 120 bus stops")
        XCTAssertEqual(count(0.1), 220, "span ≤ 0.3: up to 220 bus stops")
        // Either side of the 0.3° band edge (viewport deltas are recomputed
        // from edges, so stay clear of the exact boundary).
        XCTAssertEqual(count(0.299), 220)
        XCTAssertEqual(count(0.301), 120)
    }

    func testBusSampleIsOneStopPerCellAndDeterministic() {
        let vp = viewport(span: 0.1)
        let a = TransitViewportCuller.visibleStops(grid: denseGrid, viewport: vp, enabled: [.bus])
        XCTAssertEqual(a, TransitViewportCuller.visibleStops(grid: denseGrid, viewport: vp, enabled: [.bus]))
        let cell = TransitViewportCuller.sampleCellSize(latDelta: vp.latDelta, centerLat: vp.centerLat)
        let cells = a.map { TransitSpatialGrid.Cell(row: Int(($0.latitude / cell.lat).rounded(.down)),
                                                    col: Int(($0.longitude / cell.lon).rounded(.down))) }
        XCTAssertEqual(Set(cells).count, a.count, "at most one stop per sampling cell")
        // Everything shown lies inside the viewport plus 10%.
        let box = vp.padded(by: TransitViewportCuller.padding)
        XCTAssertTrue(a.allSatisfy { box.contains(lat: $0.latitude, lon: $0.longitude) })
    }

    /// A small pan keeps most of the sample: only edge stops come and go,
    /// so the map's annotation diff stays small.
    func testPanChangesOnlyEdgeStops() {
        for span in [0.5, 0.15, 0.03] {
            let a = Set(TransitViewportCuller.visibleStops(grid: denseGrid, viewport: viewport(span: span), enabled: [.bus]).map(\.id))
            let shifted = GeoBox(minLat: center.lat - span / 2 + span * 0.1, maxLat: center.lat + span / 2 + span * 0.1,
                                 minLon: center.lon - span / 2 + span * 0.1, maxLon: center.lon + span / 2 + span * 0.1)
            let b = Set(TransitViewportCuller.visibleStops(grid: denseGrid, viewport: shifted, enabled: [.bus]).map(\.id))
            let kept = Double(a.intersection(b).count) / Double(max(a.count, 1))
            XCTAssertGreaterThan(kept, 0.6, "span \(span): a 10% pan keeps most stops (kept \(kept))")
        }
    }

    func testBusBudgetBands() {
        XCTAssertEqual(TransitViewportCuller.busBudget(latDelta: 0.005), 220)
        XCTAssertEqual(TransitViewportCuller.busBudget(latDelta: 0.1), 220)
        XCTAssertEqual(TransitViewportCuller.busBudget(latDelta: 0.3), 220)
        XCTAssertEqual(TransitViewportCuller.busBudget(latDelta: 0.31), 120)
        XCTAssertEqual(TransitViewportCuller.busBudget(latDelta: 1.0), 120)
    }

    // MARK: Zoom buckets

    func testAnnotationSizeThresholds() {
        XCTAssertEqual(AnnotationSize(latitudeDelta: 0.6), .dot)
        XCTAssertEqual(AnnotationSize(latitudeDelta: 0.081), .dot)
        XCTAssertEqual(AnnotationSize(latitudeDelta: 0.08), .compact)
        XCTAssertEqual(AnnotationSize(latitudeDelta: 0.021), .compact)
        XCTAssertEqual(AnnotationSize(latitudeDelta: 0.02), .full)
        XCTAssertEqual(AnnotationSize(latitudeDelta: 0.005), .full)
    }

    func testTransitZoomBucket() {
        XCTAssertEqual(TransitZoomBucket(latitudeDelta: 0.5), TransitZoomBucket(bus: .dot, rail: .dot))
        XCTAssertEqual(TransitZoomBucket(latitudeDelta: 0.05), TransitZoomBucket(bus: .dot, rail: .compact))
        XCTAssertEqual(TransitZoomBucket(latitudeDelta: 0.008), TransitZoomBucket(bus: .compact, rail: .full))
        XCTAssertEqual(TransitZoomBucket(latitudeDelta: 0.004), TransitZoomBucket(bus: .full, rail: .full))
        // Same bucket across a pan-sized span change: nothing to republish.
        XCTAssertEqual(TransitZoomBucket(latitudeDelta: 0.2), TransitZoomBucket(latitudeDelta: 0.15))
        let bucket = TransitZoomBucket(latitudeDelta: 0.05)
        XCTAssertEqual(bucket.size(for: .bus), .dot)
        XCTAssertEqual(bucket.size(for: .dart), .compact)
    }

    func testBusPinSizeByZoom() {
        func size(_ d: Double) -> AnnotationSize { TransitViewportCuller.pinSize(for: .bus, latitudeDelta: d) }
        XCTAssertEqual(size(0.04), .dot, "city zoom: dots, not a carpet of icons")
        XCTAssertEqual(size(0.012), .dot)
        XCTAssertEqual(size(0.0119), .compact)
        XCTAssertEqual(size(0.005), .compact)
        XCTAssertEqual(size(0.0049), .full)
    }

    func testRailPinsSwitchOneLevelEarlier() {
        for kind in [TransitLayerKind.luas, .dart, .rail] {
            XCTAssertEqual(TransitViewportCuller.pinSize(for: kind, latitudeDelta: 0.2), .dot)
            XCTAssertEqual(TransitViewportCuller.pinSize(for: kind, latitudeDelta: 0.04), .compact)
            XCTAssertEqual(TransitViewportCuller.pinSize(for: kind, latitudeDelta: 0.012), .compact)
            XCTAssertEqual(TransitViewportCuller.pinSize(for: kind, latitudeDelta: 0.008), .full)
        }
    }

    func testDisabledKindsAndMultiKindStops() {
        let connolly = TransitStop(id: "c", name: "Connolly", latitude: center.lat, longitude: center.lon,
                                   kind: .dart, kinds: [.dart, .rail])
        let grid = TransitSpatialGrid(stops: [connolly] + stops(.bus, count: 5, radius: 0.001, prefix: "b"))
        let railOnly = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.01), enabled: [.rail])
        XCTAssertEqual(railOnly.map(\.id), ["c"])
        XCTAssertTrue(TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.01), enabled: []).isEmpty)
    }

    func testVisibleLines() {
        let inView = TransitLine(id: "luas-red", kind: .luas, line: "red", name: "Red",
                                 coords: [[53.34, -6.27], [53.35, -6.25]])
        let away = TransitLine(id: "rail-x", kind: .rail, name: "Far", coords: [[52.0, -8.0], [52.1, -8.1]])
        let dart = TransitLine(id: "dart", kind: .dart, name: "DART", coords: [[53.34, -6.24], [53.36, -6.22]])
        let lines = [inView, away, dart]
        let vp = viewport(span: 0.05)
        XCTAssertEqual(TransitViewportCuller.visibleLines(lines, viewport: vp, enabled: [.luas, .rail]).map(\.id),
                       ["luas-red"])
        XCTAssertEqual(TransitViewportCuller.visibleLines(lines, viewport: vp, enabled: Set(TransitLayerKind.allCases)).map(\.id),
                       ["luas-red", "dart"])
    }

    @MainActor
    func testStoreRecomputesVisibleSubset() async throws {
        let store = TransitLayerStore(region: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        store.apply(TransitBundle(stops: stops(.bus, count: 20, radius: 0.005, prefix: "b")
                                    + stops(.luas, count: 3, radius: 0.005, prefix: "l"),
                                  lines: [], routes: []))
        XCTAssertTrue(store.visibleStops.isEmpty, "nothing enabled yet")
        store.enabledKinds = [.luas]
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.visibleStops.count, 3)
        store.enabledKinds = []
        XCTAssertTrue(store.visibleStops.isEmpty)
    }

    /// A recompute that yields the same stops, lines and bucket publishes
    /// nothing, so the map content is not invalidated by a no-op pan.
    @MainActor
    func testIdenticalRecomputeDoesNotPublish() async throws {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        let store = TransitLayerStore(region: region)
        store.apply(TransitBundle(stops: stops(.bus, count: 20, radius: 0.005, prefix: "b"),
                                  lines: [], routes: []))
        store.enabledKinds = [.bus]
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(store.visibleStops.isEmpty)

        let changed = ChangeFlag()
        withObservationTracking {
            _ = store.visibleStops
            _ = store.visibleLines
            _ = store.zoomBucket
        } onChange: {
            changed.set()
        }
        store.region = region
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(changed.isSet, "an identical recompute must not publish")
    }

    /// A recompute publishes the full culled set in one step and bumps
    /// `version` once; disabling every kind clears it and bumps again.
    @MainActor
    func testPublishBumpsVersionOncePerChange() async throws {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
        let store = TransitLayerStore(region: region)
        store.apply(TransitBundle(stops: denseBus, lines: [], routes: []))
        let expected = TransitViewportCuller.visibleStops(grid: denseGrid, viewport: GeoBox(region: region), enabled: [.bus])
        let v0 = store.version
        store.enabledKinds = [.bus]
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.visibleStops, expected)
        XCTAssertEqual(store.version, v0 + 1)
        store.region = region
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.version, v0 + 1, "identical recompute: no bump")
        store.enabledKinds = []
        XCTAssertTrue(store.visibleStops.isEmpty)
        XCTAssertEqual(store.version, v0 + 2)
    }

    @MainActor
    func testNearestDotStopOnlyMatchesVisibleDots() async throws {
        let near = makeStop(id: "near", name: "Near", lat: center.lat + 0.0005, lon: center.lon, type: .bus)
        let store = TransitLayerStore(region: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)))
        store.apply(TransitBundle(stops: [near], lines: [], routes: []))
        let tap = CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)
        XCTAssertNil(store.nearestDotStop(to: tap, within: 200), "bus off: not visible, not tappable")
        store.enabledKinds = [.bus]
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.nearestDotStop(to: tap, within: 200)?.id, "near")
        XCTAssertNil(store.nearestDotStop(to: tap, within: 20), "outside the tap radius")
    }
}
