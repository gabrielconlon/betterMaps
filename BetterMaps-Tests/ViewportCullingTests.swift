import XCTest
import MapKit
import Observation
@testable import CustomMapApp

/// `MapContentStore.cull` is pure, so these tests need no SwiftData.
final class ViewportCullingTests: XCTestCase {

    let brunch = LayerLite(id: UUID(), name: "Brunch", colorHex: "#111111", sortOrder: 0)
    let favorites = LayerLite(id: UUID(), name: "Favorites", colorHex: "#222222", sortOrder: 1)
    let trailLayer = LayerLite(id: UUID(), name: "Canal Walk", colorHex: "#333333", kind: .waypointPath, sortOrder: 2)
    let hiddenTrail = LayerLite(id: UUID(), name: "Hidden Walk", isVisible: false, kind: .waypointPath, sortOrder: 3)

    var layers: [LayerLite] { [brunch, favorites, trailLayer, hiddenTrail] }

    /// Dublin city centre, 0.2° span: the launch zoom (a "dot" viewport).
    let launchViewport = GeoBox(minLat: 53.2498, maxLat: 53.4498, minLon: -6.3603, maxLon: -6.1603)
    /// 0.01° span: city zoom (full pins, no clustering).
    let cityViewport = GeoBox(minLat: 53.3448, maxLat: 53.3548, minLon: -6.2653, maxLon: -6.2553)

    func place(_ name: String, lat: Double, lon: Double, in layerIds: [UUID]) -> PlaceLite {
        PlaceLite(id: UUID(), name: name, latitude: lat, longitude: lon, layerIds: layerIds)
    }

    func cull(_ places: [PlaceLite], trails: [TrailLite] = [], mode: FilterMode = .union,
              viewport: GeoBox, size: CGSize = CGSize(width: 390, height: 844)) -> CullOutput {
        MapContentStore.cull(places: places, layers: layers, trails: trails, mode: mode,
                             viewport: viewport, mapWidth: size.width, mapHeight: size.height)
    }

    // MARK: - Viewport

    func testExcludesPlacesOutsidePaddedViewportAndKeepsInside() {
        let inside = place("inside", lat: 53.35, lon: -6.26, in: [brunch.id])
        // 30% padding on a 0.2° span adds 0.06° per side: 53.4498 + 0.06 = 53.5098 is the edge.
        let inPadding = place("padding", lat: 53.50, lon: -6.26, in: [brunch.id])
        let outside = place("outside", lat: 53.60, lon: -6.26, in: [brunch.id])
        let farWest = place("west", lat: 53.35, lon: -7.0, in: [brunch.id])

        let out = cull([inside, inPadding, outside, farWest], viewport: cityViewport.padded(by: 0))
        XCTAssertEqual(out.places.map(\.id), [inside.id], "city viewport keeps only the centre place")

        let launch = cull([inside, inPadding, outside, farWest], viewport: launchViewport)
        let kept = Set(launch.places.map(\.id) + launch.clusters.flatMap { _ in [UUID]() })
        XCTAssertTrue(kept.contains(inside.id))
        XCTAssertTrue(kept.contains(inPadding.id), "30% padding keeps a place just past the edge")
        XCTAssertFalse(kept.contains(outside.id))
        XCTAssertFalse(kept.contains(farWest.id))
        XCTAssertEqual(launch.annotationSize, .dot)
    }

    func testHiddenLayerPlacesAreFilteredOut() {
        let hidden = LayerLite(id: UUID(), name: "Hidden", isVisible: false)
        let p = place("p", lat: 53.35, lon: -6.26, in: [hidden.id])
        let out = MapContentStore.cull(places: [p], layers: [hidden], trails: [], mode: .union,
                                       viewport: cityViewport, mapWidth: 390, mapHeight: 844)
        XCTAssertTrue(out.places.isEmpty)
        XCTAssertEqual(out.visibleLayerCount, 0)
    }

    // MARK: - Clustering

    func testClusterCountsSumToInputCountAtDotZoom() {
        // Two tight groups (well inside one 48pt cell each) plus three scattered singles.
        var places: [PlaceLite] = []
        for i in 0..<5 { places.append(place("a\(i)", lat: 53.3400 + Double(i) * 0.0001, lon: -6.2600, in: [brunch.id])) }
        for i in 0..<3 { places.append(place("b\(i)", lat: 53.4000 + Double(i) * 0.0001, lon: -6.2000, in: [favorites.id])) }
        places.append(place("s1", lat: 53.30, lon: -6.30, in: [brunch.id]))
        places.append(place("s2", lat: 53.32, lon: -6.20, in: [brunch.id]))
        places.append(place("s3", lat: 53.42, lon: -6.32, in: [favorites.id]))

        let out = cull(places, viewport: launchViewport)
        XCTAssertEqual(out.annotationSize, .dot)
        XCTAssertFalse(out.clusters.isEmpty, "tight groups must cluster at dot zoom")
        XCTAssertEqual(out.places.count + out.clusters.reduce(0) { $0 + $1.count }, places.count,
                       "every input place is either a single pin or counted in exactly one cluster")
        XCTAssertTrue(out.clusters.allSatisfy { $0.count >= 2 })

        // Cluster color comes from the first member's primary layer.
        let brunchCluster = out.clusters.first { $0.count == 5 }
        XCTAssertEqual(brunchCluster?.colorHex, brunch.colorHex)
        XCTAssertEqual(brunchCluster.map { $0.latitude }!, 53.3402, accuracy: 0.0001, "mean coordinate")
    }

    func testNoClustersAtCityZoom() {
        var places: [PlaceLite] = []
        for i in 0..<5 { places.append(place("a\(i)", lat: 53.3500 + Double(i) * 0.00001, lon: -6.2600, in: [brunch.id])) }
        let out = cull(places, viewport: cityViewport)
        XCTAssertEqual(out.annotationSize, .full)
        XCTAssertTrue(out.clusters.isEmpty)
        XCTAssertEqual(out.places.count, 5)
    }

    func testClusterCellSizeFollowsMapHeight() {
        // 0.2° over 844pt → cell ≈ 0.0114°. Two places 0.05° apart never share a cell.
        let a = place("a", lat: 53.30, lon: -6.26, in: [brunch.id])
        let b = place("b", lat: 53.35, lon: -6.26, in: [brunch.id])
        let out = cull([a, b], viewport: launchViewport)
        XCTAssertTrue(out.clusters.isEmpty)
        XCTAssertEqual(out.places.count, 2)
    }

    // MARK: - Trails

    func trail(layer: LayerLite, from: (Double, Double), to: (Double, Double)) -> TrailLite {
        TrailLite(id: UUID(), layerId: layer.id, colorHex: layer.colorHex, lineWidth: 4, name: "t",
                  segments: [TrailSegmentLite(coords: [[from.0, from.1], [to.0, to.1]], snapped: false)])!
    }

    func testTrailIncludedOnlyWhenBBoxIntersectsPaddedViewport() {
        let crossing = trail(layer: trailLayer, from: (53.0, -6.5), to: (53.6, -6.0))   // spans the viewport
        let touching = trail(layer: trailLayer, from: (53.50, -6.26), to: (53.55, -6.26)) // starts in the 30% pad
        let far = trail(layer: trailLayer, from: (52.0, -8.0), to: (52.1, -8.1))
        let hidden = trail(layer: hiddenTrail, from: (53.3, -6.3), to: (53.4, -6.2))

        let out = cull([], trails: [crossing, touching, far, hidden], viewport: launchViewport)
        XCTAssertEqual(Set(out.trails.map(\.id)), [crossing.id, touching.id])
    }

    func testTrailLiteBBoxCoversEverySegment() {
        let t = TrailLite(id: UUID(), layerId: trailLayer.id, colorHex: "#000000", lineWidth: 2, name: "t",
                          segments: [
                            TrailSegmentLite(coords: [[53.34, -6.26], [53.35, -6.25]], snapped: false),
                            TrailSegmentLite(coords: [[53.35, -6.25], [53.30, -6.20]], snapped: true),
                          ])
        XCTAssertEqual(t?.bbox, GeoBox(minLat: 53.30, maxLat: 53.35, minLon: -6.26, maxLon: -6.20))
        XCTAssertNil(TrailLite(id: UUID(), layerId: trailLayer.id, colorHex: "#000000", lineWidth: 2,
                               name: "empty", segments: []))
    }

    // MARK: - Legend

    func testLegendPassesThroughLayerMathForWholeFilteredSet() {
        let shared1 = place("s1", lat: 53.35, lon: -6.26, in: [brunch.id, favorites.id])
        let shared2 = place("s2", lat: 53.351, lon: -6.261, in: [brunch.id, favorites.id])
        let offscreenShared = place("s3", lat: 54.5, lon: -6.26, in: [brunch.id, favorites.id])
        let single = place("single", lat: 53.352, lon: -6.262, in: [brunch.id])
        let places = [shared1, shared2, offscreenShared, single]

        let out = cull(places, mode: .intersection, viewport: cityViewport)
        let expected = LayerMath.intersectionLegend(
            LayerMath.filter(places, layers: layers, mode: .intersection), layers: layers)
        XCTAssertEqual(out.legend, expected)
        XCTAssertEqual(out.legend.first?.label, "Brunch + Favorites")
        XCTAssertEqual(out.legend.first?.count, 3, "legend counts the whole filtered set, not just the viewport")
        XCTAssertEqual(out.places.map(\.id), [shared1.id, shared2.id], "intersection drops the single, viewport drops s3")
        XCTAssertEqual(out.visibleLayerCount, 3)
    }

    // MARK: - Store publishing

    func testCullOutputEquality() {
        let p = place("p", lat: 53.35, lon: -6.26, in: [brunch.id])
        XCTAssertEqual(cull([p], viewport: cityViewport), cull([p], viewport: cityViewport))
        XCTAssertNotEqual(cull([p], viewport: cityViewport), cull([], viewport: cityViewport))
    }

    /// Recomputing with identical inputs (a settle at the same camera) must
    /// not replace `output` or notify observers.
    @MainActor
    func testIdenticalRecomputeDoesNotPublish() async throws {
        let store = MapContentStore(region: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        store.mapSize = CGSize(width: 390, height: 844)
        let places = [place("p", lat: 53.35, lon: -6.26, in: [brunch.id])]
        store.update(places: places, layers: layers, trails: [])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.output.places.count, 1)
        let published = store.debugPublishCount

        let changed = ChangeFlag()
        withObservationTracking { _ = store.output } onChange: { changed.set() }
        store.update(places: places, layers: layers, trails: [])
        let sameRegion = store.region
        store.region = sameRegion
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.debugPublishCount, published)
        XCTAssertFalse(changed.isSet, "an identical recompute must not publish")

        // A real change still publishes.
        store.update(places: [], layers: layers, trails: [])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.debugPublishCount, published + 1)
        XCTAssertTrue(changed.isSet)
    }

    // MARK: - GeoBox

    func testGeoBoxPaddingAndIntersection() {
        let box = GeoBox(minLat: 0, maxLat: 1, minLon: 0, maxLon: 2)
        XCTAssertEqual(box.padded(by: 0.5), GeoBox(minLat: -0.5, maxLat: 1.5, minLon: -1, maxLon: 3))
        XCTAssertTrue(box.intersects(GeoBox(minLat: 0.9, maxLat: 2, minLon: 1.9, maxLon: 3)))
        XCTAssertFalse(box.intersects(GeoBox(minLat: 1.1, maxLat: 2, minLon: 0, maxLon: 1)))
        XCTAssertTrue(box.contains(lat: 1, lon: 2))
        XCTAssertFalse(box.contains(lat: 1.0001, lon: 2))
    }
}
