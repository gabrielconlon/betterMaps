import XCTest
import MapKit
@testable import CustomMapApp

/// Deterministic RNG so the random-stop tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

final class TransitSpatialGridTests: XCTestCase {

    func testCellBoundaryMembership() {
        let onEdge = makeStop(id: "edge", name: "Edge", lat: 53.35, lon: -6.26)
        let below = makeStop(id: "below", name: "Below", lat: 53.3499, lon: -6.26)
        let above = makeStop(id: "above", name: "Above", lat: 53.3501, lon: -6.26)
        let grid = TransitSpatialGrid(stops: [onEdge, below, above])

        XCTAssertNotEqual(TransitSpatialGrid.cell(lat: below.latitude, lon: below.longitude),
                          TransitSpatialGrid.cell(lat: above.latitude, lon: above.longitude))

        // Boxes ending or starting exactly on the boundary both include it.
        let upper = GeoBox(minLat: 53.35, maxLat: 53.36, minLon: -6.27, maxLon: -6.25)
        let lower = GeoBox(minLat: 53.34, maxLat: 53.35, minLon: -6.27, maxLon: -6.25)
        XCTAssertEqual(Set(grid.stops(in: upper).map(\.id)), ["edge", "above"])
        XCTAssertEqual(Set(grid.stops(in: lower).map(\.id)), ["edge", "below"])

        // A box that starts just past the boundary excludes it.
        let past = GeoBox(minLat: 53.35005, maxLat: 53.36, minLon: -6.27, maxLon: -6.25)
        XCTAssertEqual(Set(grid.stops(in: past).map(\.id)), ["above"])

        // Longitude boundary (negative) behaves the same.
        let west = makeStop(id: "west", name: "W", lat: 53.355, lon: -6.2600001)
        let east = makeStop(id: "east", name: "E", lat: 53.355, lon: -6.2599999)
        let lonGrid = TransitSpatialGrid(stops: [west, east])
        XCTAssertEqual(Set(lonGrid.stops(in: GeoBox(minLat: 53.35, maxLat: 53.36,
                                                    minLon: -6.26, maxLon: -6.25)).map(\.id)), ["east"])
    }

    func testQueryMatchesLinearScanOnRandomStops() {
        var rng = SeededGenerator(seed: 42)
        let stops = (0..<2000).map { i in
            makeStop(id: "s\(i)", name: "Stop \(i)",
                     lat: Double.random(in: 53.15...53.65, using: &rng),
                     lon: Double.random(in: -6.65 ... -5.95, using: &rng),
                     type: TransitLayerKind.allCases[i % 4])
        }
        let grid = TransitSpatialGrid(stops: stops)
        XCTAssertEqual(grid.count, 2000)

        for _ in 0..<50 {
            let lat = Double.random(in: 53.1...53.7, using: &rng)
            let lon = Double.random(in: -6.7 ... -5.9, using: &rng)
            let span = Double.random(in: 0.002...0.6, using: &rng)
            let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.5))
            let padding = Double.random(in: 0...0.5, using: &rng)
            let box = GeoBox(region: region).padded(by: padding)
            let expected = Set(stops.filter { box.contains(lat: $0.latitude, lon: $0.longitude) }.map(\.id))
            XCTAssertEqual(Set(grid.query(region, padding: padding).map(\.id)), expected)
        }

        // Whole-country box takes the sparse-cell path and still matches.
        let all = GeoBox(minLat: 50, maxLat: 56, minLon: -11, maxLon: -5)
        XCTAssertEqual(grid.stops(in: all).count, 2000)
    }

    func testNearestIsSortedAndWithinRadius() {
        let origin = CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603)
        let stops = [
            makeStop(id: "far", name: "Far", lat: 53.3540, lon: -6.2603),     // ~470 m
            makeStop(id: "mid", name: "Mid", lat: 53.3510, lon: -6.2603),     // ~130 m
            makeStop(id: "near", name: "Near", lat: 53.3500, lon: -6.2603),   // ~20 m
            makeStop(id: "rail", name: "Rail", lat: 53.3505, lon: -6.2603, type: .rail),
        ]
        let grid = TransitSpatialGrid(stops: stops)
        XCTAssertEqual(grid.nearest(to: origin, within: 200).map(\.id), ["near", "rail", "mid"])
        XCTAssertEqual(grid.nearest(to: origin, within: 200, where: { $0.kind != .bus }).map(\.id), ["rail"])
    }
}
