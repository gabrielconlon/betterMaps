import Foundation
import MapKit

/// Uniform 0.01° grid over a stop set. Built once when the bundle loads; a
/// viewport query visits only the cells overlapping the (padded) region.
struct TransitSpatialGrid: Sendable {
    static let cellSize = 0.01

    struct Cell: Hashable, Sendable { let row: Int; let col: Int }

    private let cells: [Cell: [TransitStop]]
    let count: Int

    init(stops: [TransitStop]) {
        var cells: [Cell: [TransitStop]] = [:]
        for stop in stops {
            cells[Self.cell(lat: stop.latitude, lon: stop.longitude), default: []].append(stop)
        }
        self.cells = cells
        self.count = stops.count
    }

    static func cell(lat: Double, lon: Double) -> Cell {
        Cell(row: Int((lat / cellSize).rounded(.down)), col: Int((lon / cellSize).rounded(.down)))
    }

    /// Stops inside `region` grown by `padding` × its span on every side.
    func query(_ region: MKCoordinateRegion, padding: Double) -> [TransitStop] {
        stops(in: GeoBox(region: region).padded(by: padding))
    }

    /// Stops inside `box` (edges inclusive), in grid-cell order.
    func stops(in box: GeoBox) -> [TransitStop] {
        guard !cells.isEmpty, box.minLat <= box.maxLat, box.minLon <= box.maxLon else { return [] }
        let lo = Self.cell(lat: box.minLat, lon: box.minLon)
        let hi = Self.cell(lat: box.maxLat, lon: box.maxLon)
        let span = (hi.row - lo.row + 1) * (hi.col - lo.col + 1)
        var out: [TransitStop] = []
        if span > cells.count {
            // Zoomed far out: walking the occupied cells is cheaper.
            for (cell, bucket) in cells
            where cell.row >= lo.row && cell.row <= hi.row && cell.col >= lo.col && cell.col <= hi.col {
                for stop in bucket where box.contains(lat: stop.latitude, lon: stop.longitude) {
                    out.append(stop)
                }
            }
            return out
        }
        for row in lo.row...hi.row {
            for col in lo.col...hi.col {
                guard let bucket = cells[Cell(row: row, col: col)] else { continue }
                for stop in bucket where box.contains(lat: stop.latitude, lon: stop.longitude) {
                    out.append(stop)
                }
            }
        }
        return out
    }

    /// Stops within `meters` of `coordinate`, nearest first.
    func nearest(to coordinate: CLLocationCoordinate2D, within meters: Double,
                 where include: (TransitStop) -> Bool = { _ in true }) -> [TransitStop] {
        nearestWithDistance(to: coordinate, within: meters, where: include).map(\.stop)
    }

    /// `nearest`, with each stop's distance from `coordinate` in metres so a
    /// caller that shows the distance need not measure it again.
    func nearestWithDistance(to coordinate: CLLocationCoordinate2D, within meters: Double,
                             where include: (TransitStop) -> Bool = { _ in true }) -> [(stop: TransitStop, meters: Double)] {
        let dLat = meters / 111_000
        let dLon = meters / (111_000 * max(cos(coordinate.latitude * .pi / 180), 0.01))
        let box = GeoBox(minLat: coordinate.latitude - dLat, maxLat: coordinate.latitude + dLat,
                         minLon: coordinate.longitude - dLon, maxLon: coordinate.longitude + dLon)
        return stops(in: box)
            .filter(include)
            .map { (stop: $0, meters: WaypointGraph.meters($0.coordinate, coordinate)) }
            .filter { $0.meters <= meters }
            .sorted { $0.meters < $1.meters }
    }
}

/// Coarse zoom bucket for transit pins: the pin size of bus stops and of
/// Luas/DART/rail stops at a span. It only changes when a size threshold is
/// crossed, so views keyed on it don't redraw on every camera move.
struct TransitZoomBucket: Sendable, Equatable {
    var bus: AnnotationSize
    var rail: AnnotationSize

    init(bus: AnnotationSize, rail: AnnotationSize) {
        self.bus = bus
        self.rail = rail
    }

    init(latitudeDelta: Double) {
        self.init(bus: TransitViewportCuller.pinSize(for: .bus, latitudeDelta: latitudeDelta),
                  rail: TransitViewportCuller.pinSize(for: .rail, latitudeDelta: latitudeDelta))
    }

    /// Pin size for a stop whose primary network is `kind`.
    func size(for kind: TransitLayerKind) -> AnnotationSize {
        kind == .bus ? bus : rail
    }
}

/// Pure viewport filtering for the transit layer; runs off-main.
enum TransitViewportCuller {
    /// Bus stops are hidden above this latitude span (country-wide view).
    static let busMaxLatDelta = 1.0
    /// Above this span (up to `busMaxLatDelta`) the regional bus budget
    /// applies; at or below it, the city one.
    static let regionalLatDelta = 0.3
    static let busBudgetCity = 220
    static let busBudgetRegional = 120
    /// Each side of the viewport is grown by this fraction before querying,
    /// so small pans don't pop stops in at the edge.
    static let padding = 0.1
    /// Bus sampling grid: a power-of-two span level is split into this many
    /// cells per side, and each cell shows at most one stop.
    static let sampleCellsPerLevel = 32.0

    static func busBudget(latDelta: Double) -> Int {
        latDelta <= regionalLatDelta ? busBudgetCity : busBudgetRegional
    }

    // MARK: Pin size by zoom

    /// Bus stops: `.dot` until the span drops below this, then `.compact`.
    static let busCompactBelow = 0.012
    /// Bus stops: `.full` (icon pin + name) only below this span.
    static let busFullBelow = 0.005
    /// Luas/DART/rail switch one level earlier: compact below 0.08 (the
    /// place-pin dot threshold), full where bus turns compact.
    static let railCompactBelow = 0.08
    static let railFullBelow = busCompactBelow

    /// Pin presentation for a stop of `kind` at `latitudeDelta`. Keeps a city
    /// view of hundreds of bus stops to small dots instead of a carpet of
    /// overlapping icons.
    static func pinSize(for kind: TransitLayerKind, latitudeDelta: Double) -> AnnotationSize {
        let (compactBelow, fullBelow) = kind == .bus
            ? (busCompactBelow, busFullBelow)
            : (railCompactBelow, railFullBelow)
        if latitudeDelta < fullBelow { return .full }
        if latitudeDelta < compactBelow { return .compact }
        return .dot
    }

    /// Visible stops for `viewport`: Luas/DART/rail first and uncapped, then
    /// a stable sample of bus stops (if enabled and not zoomed out past
    /// `busMaxLatDelta`) up to the zoom's budget.
    ///
    /// Bus sampling is deterministic so a pan only adds and removes stops at
    /// the edges: the span is quantized to a power-of-two level, that level's
    /// fixed lat/lon grid keeps one stop per cell (lowest `priority`), and if
    /// that is still over budget the lowest-priority representatives win.
    /// Grids of neighbouring levels nest, so zooming in keeps the stops
    /// already shown.
    static func visibleStops(grid: TransitSpatialGrid, viewport: GeoBox,
                             enabled: Set<TransitLayerKind>) -> [TransitStop] {
        guard !enabled.isEmpty else { return [] }
        let candidates = grid.stops(in: viewport.padded(by: padding))
        var rail: [TransitStop] = []
        let showBus = enabled.contains(.bus) && viewport.latDelta <= busMaxLatDelta
        let cell = sampleCellSize(latDelta: viewport.latDelta, centerLat: viewport.centerLat)
        var best: [TransitSpatialGrid.Cell: (stop: TransitStop, priority: UInt64)] = [:]
        for stop in candidates {
            if stop.kinds.contains(where: { $0 != .bus && enabled.contains($0) }) {
                rail.append(stop)
            } else if showBus && stop.isServed(by: .bus) {
                let key = TransitSpatialGrid.Cell(row: Int((stop.latitude / cell.lat).rounded(.down)),
                                                  col: Int((stop.longitude / cell.lon).rounded(.down)))
                let p = priority(of: stop)
                if let current = best[key], current.priority <= p { continue }
                best[key] = (stop, p)
            }
        }
        let bus = best.values
            .sorted { $0.priority < $1.priority }
            .prefix(busBudget(latDelta: viewport.latDelta))
            .map(\.stop)
        return rail + bus
    }

    /// Sampling cell for a span: `2^ceil(log2 latDelta) / sampleCellsPerLevel`
    /// degrees of latitude, and roughly square on screen in longitude (the
    /// cosine is taken at latitude rounded to 5° so a pan never changes it).
    static func sampleCellSize(latDelta: Double, centerLat: Double) -> (lat: Double, lon: Double) {
        let level = pow(2, log2(max(latDelta, 1e-6)).rounded(.up))
        let lat = level / sampleCellsPerLevel
        let roundedLat = (centerLat / 5).rounded() * 5
        let lon = lat / max(cos(roundedLat * .pi / 180), 0.1)
        return (lat, lon)
    }

    /// Fixed per-stop priority (FNV-1a of the stop id): the same stop wins
    /// its cell on every query and in every process.
    static func priority(of stop: TransitStop) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in stop.id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Network lines of enabled kinds that overlap the padded viewport.
    static func visibleLines(_ lines: [TransitLine], viewport: GeoBox,
                             enabled: Set<TransitLayerKind>) -> [TransitLine] {
        let box = viewport.padded(by: padding)
        return lines.filter { enabled.contains($0.kind) && $0.bbox.intersects(box) }
    }
}
