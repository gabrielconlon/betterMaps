import Foundation
import MapKit
import Observation

// MARK: - Value types the map renders from

/// Axis-aligned lat/lon box. Plain doubles so it is trivially `Sendable`
/// and testable without MapKit.
struct GeoBox: Sendable, Hashable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }

    init(region: MKCoordinateRegion) {
        let c = region.center
        let s = region.span
        self.init(minLat: c.latitude - s.latitudeDelta / 2,
                  maxLat: c.latitude + s.latitudeDelta / 2,
                  minLon: c.longitude - s.longitudeDelta / 2,
                  maxLon: c.longitude + s.longitudeDelta / 2)
    }

    /// Smallest box containing every coordinate. `nil` when `coords` is empty.
    init?(containing coords: [[Double]]) {
        var box: GeoBox?
        for pair in coords where pair.count >= 2 {
            if var b = box {
                b.minLat = min(b.minLat, pair[0]); b.maxLat = max(b.maxLat, pair[0])
                b.minLon = min(b.minLon, pair[1]); b.maxLon = max(b.maxLon, pair[1])
                box = b
            } else {
                box = GeoBox(minLat: pair[0], maxLat: pair[0], minLon: pair[1], maxLon: pair[1])
            }
        }
        guard let box else { return nil }
        self = box
    }

    var latDelta: Double { maxLat - minLat }
    var lonDelta: Double { maxLon - minLon }
    var centerLat: Double { (minLat + maxLat) / 2 }
    var centerLon: Double { (minLon + maxLon) / 2 }

    /// Grows the box by `fraction` of its size on every side.
    func padded(by fraction: Double) -> GeoBox {
        let dLat = latDelta * fraction
        let dLon = lonDelta * fraction
        return GeoBox(minLat: minLat - dLat, maxLat: maxLat + dLat,
                      minLon: minLon - dLon, maxLon: maxLon + dLon)
    }

    func contains(lat: Double, lon: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
    }

    func intersects(_ other: GeoBox) -> Bool {
        !(other.minLat > maxLat || other.maxLat < minLat ||
          other.minLon > maxLon || other.maxLon < minLon)
    }
}

struct TrailSegmentLite: Sendable, Hashable {
    /// `[[lat, lon], ...]`
    let coords: [[Double]]
    let snapped: Bool

    var coordinates: [CLLocationCoordinate2D] {
        coords.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
}

/// Snapshot of one `Trail` plus the layer styling it needs to draw.
struct TrailLite: Sendable, Identifiable, Hashable {
    let id: UUID
    let layerId: UUID
    let colorHex: String
    let lineWidth: Double
    let name: String
    let segments: [TrailSegmentLite]
    let bbox: GeoBox

    init(id: UUID, layerId: UUID, colorHex: String, lineWidth: Double, name: String,
         segments: [TrailSegmentLite], bbox: GeoBox) {
        self.id = id
        self.layerId = layerId
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.name = name
        self.segments = segments
        self.bbox = bbox
    }

    /// Builds the trail with its bbox derived from `segments`. `nil` when there
    /// is nothing to draw.
    init?(id: UUID, layerId: UUID, colorHex: String, lineWidth: Double, name: String,
          segments: [TrailSegmentLite]) {
        guard let bbox = GeoBox(containing: segments.flatMap(\.coords)) else { return nil }
        self.init(id: id, layerId: layerId, colorHex: colorHex, lineWidth: lineWidth,
                  name: name, segments: segments, bbox: bbox)
    }
}

/// A grid cell at far zoom holding two or more places.
struct ClusterLite: Sendable, Identifiable, Hashable {
    let id: String
    let latitude: Double
    let longitude: Double
    let count: Int
    let colorHex: String
    /// Size of the grid cell this cluster came from, so a tap can zoom to it.
    let cellLatDelta: Double
    let cellLonDelta: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct CullOutput: Sendable {
    var places: [MatchedPlace]
    var clusters: [ClusterLite]
    var trails: [TrailLite]
    var legend: [LegendEntry]
    var visibleLayerCount: Int
    /// Pin size class for the viewport the output was computed for.
    var annotationSize: AnnotationSize

    static let empty = CullOutput(places: [], clusters: [], trails: [], legend: [],
                                  visibleLayerCount: 0, annotationSize: .compact)
}

// MARK: - Store

/// Owns everything the `Map` draws. Inputs are value snapshots set by the
/// screen; any change debounces (120 ms) and reruns `cull` off the main
/// actor, then publishes `output`. The map content never touches SwiftData.
@Observable
@MainActor
final class MapContentStore {
    nonisolated static let debounce: Duration = .milliseconds(120)
    /// Viewport padding on each side, as a fraction of the span.
    nonisolated static let viewportPadding = 0.3
    /// Target on-screen size of one clustering cell.
    nonisolated static let clusterCellPoints = 48.0

    private(set) var output: CullOutput = .empty
    private(set) var isComputing = false

    var region: MKCoordinateRegion {
        didSet { scheduleRecompute() }
    }
    var filterMode: FilterMode = .union {
        didSet { if filterMode != oldValue { scheduleRecompute() } }
    }
    var mapSize: CGSize = .zero {
        didSet { if mapSize != oldValue { scheduleRecompute() } }
    }

    @ObservationIgnored private var places: [PlaceLite] = []
    @ObservationIgnored private var layers: [LayerLite] = []
    @ObservationIgnored private var trails: [TrailLite] = []
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?

    init(region: MKCoordinateRegion) {
        self.region = region
    }

    func update(places: [PlaceLite], layers: [LayerLite], trails: [TrailLite]) {
        self.places = places
        self.layers = layers
        self.trails = trails
        scheduleRecompute()
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        let places = places, layers = layers, trails = trails, mode = filterMode
        let viewport = GeoBox(region: region)
        let width = Double(mapSize.width), height = Double(mapSize.height)
        isComputing = true
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Self.cull(places: places, layers: layers, trails: trails, mode: mode,
                          viewport: viewport, mapWidth: width, mapHeight: height)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.output = result
            self.isComputing = false
        }
    }

    // MARK: Pure culling

    /// Pure: filter → viewport cull (padded 30%) → grid clustering at dot
    /// zoom → trail bbox test → legend. No actors, no SwiftData.
    nonisolated static func cull(places: [PlaceLite],
                                 layers: [LayerLite],
                                 trails: [TrailLite],
                                 mode: FilterMode,
                                 viewport: GeoBox,
                                 mapWidth: Double,
                                 mapHeight: Double) -> CullOutput {
        let matched = LayerMath.filter(places, layers: layers, mode: mode)
        let legend = LayerMath.intersectionLegend(matched, layers: layers)
        let padded = viewport.padded(by: viewportPadding)
        let inView = matched.filter { padded.contains(lat: $0.place.latitude, lon: $0.place.longitude) }
        let size = AnnotationSize(latitudeDelta: viewport.latDelta)

        let visibleTrailIds = LayerMath.visibleTrailLayerIds(layers)
        let trailsInView = trails.filter { visibleTrailIds.contains($0.layerId) && $0.bbox.intersects(padded) }
        let visibleLayerCount = layers.reduce(0) { $1.isVisible ? $0 + 1 : $0 }

        guard size == .dot, !inView.isEmpty else {
            return CullOutput(places: inView, clusters: [], trails: trailsInView, legend: legend,
                              visibleLayerCount: visibleLayerCount, annotationSize: size)
        }

        let (singles, clusters) = cluster(inView, layers: layers, viewport: viewport,
                                          mapWidth: mapWidth, mapHeight: mapHeight)
        return CullOutput(places: singles, clusters: clusters, trails: trailsInView, legend: legend,
                          visibleLayerCount: visibleLayerCount, annotationSize: size)
    }

    private struct CellKey: Hashable { let row: Int; let col: Int }

    private nonisolated static func cluster(_ matched: [MatchedPlace],
                                            layers: [LayerLite],
                                            viewport: GeoBox,
                                            mapWidth: Double,
                                            mapHeight: Double) -> ([MatchedPlace], [ClusterLite]) {
        let rows = max(1.0, mapHeight / clusterCellPoints)
        let cellLat = max(viewport.latDelta / rows, 1e-6)
        let cellLon: Double
        if mapWidth > 0, viewport.lonDelta > 0 {
            cellLon = max(viewport.lonDelta / max(1.0, mapWidth / clusterCellPoints), 1e-6)
        } else {
            cellLon = cellLat / max(0.2, cos(viewport.centerLat * .pi / 180))
        }
        let colorById: [UUID: String] = Dictionary(layers.map { ($0.id, $0.colorHex) },
                                                   uniquingKeysWith: { first, _ in first })

        var order: [CellKey] = []
        var cells: [CellKey: [MatchedPlace]] = [:]
        for m in matched {
            let key = CellKey(row: Int((m.place.latitude / cellLat).rounded(.down)),
                              col: Int((m.place.longitude / cellLon).rounded(.down)))
            if cells[key] == nil { order.append(key) }
            cells[key, default: []].append(m)
        }

        var singles: [MatchedPlace] = []
        var clusters: [ClusterLite] = []
        for key in order {
            guard let members = cells[key], !members.isEmpty else { continue }
            if members.count == 1 {
                singles.append(members[0])
                continue
            }
            let n = Double(members.count)
            let lat = members.reduce(0.0) { $0 + $1.place.latitude } / n
            let lon = members.reduce(0.0) { $0 + $1.place.longitude } / n
            let hex = members[0].primaryLayerId.flatMap { colorById[$0] } ?? "#FF3B30"
            clusters.append(ClusterLite(id: "cell-\(key.row)-\(key.col)",
                                        latitude: lat, longitude: lon,
                                        count: members.count, colorHex: hex,
                                        cellLatDelta: cellLat, cellLonDelta: cellLon))
        }
        return (singles, clusters)
    }
}
