import XCTest
import MapKit
@testable import CustomMapApp

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

    func testBusHiddenBeyondThreshold() {
        let all = stops(.bus, count: 50, radius: 0.01, prefix: "b") + stops(.luas, count: 5, radius: 0.01, prefix: "l")
        let grid = TransitSpatialGrid(stops: all)
        let enabled: Set<TransitLayerKind> = [.bus, .luas]

        let far = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.081), enabled: enabled)
        XCTAssertTrue(far.allSatisfy { $0.kind == .luas })
        XCTAssertEqual(far.count, 5)

        let near = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.08), enabled: enabled)
        XCTAssertEqual(near.count, 55)
    }

    func testRailKeptWhenBusBudgetOverflows() {
        let rail = stops(.rail, count: 10, radius: 0.004, prefix: "r")
            + stops(.dart, count: 10, radius: 0.004, prefix: "d")
            + stops(.luas, count: 10, radius: 0.004, prefix: "l")
        let bus = stops(.bus, count: 1500, radius: 0.004, prefix: "b")
        let grid = TransitSpatialGrid(stops: bus + rail)
        let result = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.01),
                                                       enabled: Set(TransitLayerKind.allCases))
        XCTAssertEqual(result.filter { $0.kind != .bus }.count, 30, "every rail/DART/Luas stop survives")
        XCTAssertEqual(result.filter { $0.kind == .bus }.count, TransitViewportCuller.busBudgetCity)
        // Rail-before-bus priority.
        XCTAssertTrue(result.prefix(30).allSatisfy { $0.kind != .bus })
    }

    func testBudgetsByZoom() {
        let bus = stops(.bus, count: 1000, radius: 0.03, prefix: "b")
        let grid = TransitSpatialGrid(stops: bus)

        let city = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.03), enabled: [.bus])
        XCTAssertEqual(city.count, TransitViewportCuller.busBudgetCity)

        let regional = TransitViewportCuller.visibleStops(grid: grid, viewport: viewport(span: 0.06), enabled: [.bus])
        XCTAssertEqual(regional.count, TransitViewportCuller.busBudgetRegional)

        // The kept bus stops are the ones nearest the centre (same metric
        // as the culler: longitude scaled by cos(lat)).
        let scale = cos(center.lat * .pi / 180)
        func d2(_ s: TransitStop) -> Double {
            let dy = s.latitude - center.lat, dx = (s.longitude - center.lon) * scale
            return dx * dx + dy * dy
        }
        let padded = viewport(span: 0.06).padded(by: TransitViewportCuller.padding)
        let keptIds = Set(regional.map(\.id))
        let droppedInView = bus.filter { !keptIds.contains($0.id) && padded.contains(lat: $0.latitude, lon: $0.longitude) }
        XCTAssertFalse(droppedInView.isEmpty)
        let farthestKept = regional.map(d2).max() ?? 0
        XCTAssertTrue(droppedInView.allSatisfy { d2($0) >= farthestKept })
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
}
