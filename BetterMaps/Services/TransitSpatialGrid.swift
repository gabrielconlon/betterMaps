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
        let dLat = meters / 111_000
        let dLon = meters / (111_000 * max(cos(coordinate.latitude * .pi / 180), 0.01))
        let box = GeoBox(minLat: coordinate.latitude - dLat, maxLat: coordinate.latitude + dLat,
                         minLon: coordinate.longitude - dLon, maxLon: coordinate.longitude + dLon)
        return stops(in: box)
            .filter(include)
            .map { ($0, WaypointGraph.meters($0.coordinate, coordinate)) }
            .filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}

/// Pure viewport filtering for the transit layer; runs off-main.
enum TransitViewportCuller {
    /// Bus stops are hidden above this latitude span.
    static let busMaxLatDelta = 0.08
    /// Above this span (up to `busMaxLatDelta`) the regional bus budget applies.
    static let cityLatDelta = 0.04
    /// At or below this span the street budget applies; between it and
    /// `cityLatDelta`, the city one.
    static let streetLatDelta = 0.012
    static let busBudgetStreet = 400
    static let busBudgetCity = 250
    static let busBudgetRegional = 150
    /// Each side of the viewport is grown by this fraction before querying,
    /// so small pans don't pop stops in at the edge.
    static let padding = 0.25

    static func busBudget(latDelta: Double) -> Int {
        if latDelta <= streetLatDelta { return busBudgetStreet }
        return latDelta <= cityLatDelta ? busBudgetCity : busBudgetRegional
    }

    // MARK: Pin size by zoom

    /// Bus stops: `.dot` until the span drops below this, then `.compact`.
    static let busCompactBelow = 0.012
    /// Bus stops: `.full` (icon pin + name) only below this span.
    static let busFullBelow = 0.005
    /// Luas/DART/rail switch one level earlier: compact below the point bus
    /// stops appear, full where bus turns compact.
    static let railCompactBelow = busMaxLatDelta
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
    /// bus (if enabled and zoomed in enough) nearest the centre up to the
    /// zoom's budget.
    static func visibleStops(grid: TransitSpatialGrid, viewport: GeoBox,
                             enabled: Set<TransitLayerKind>) -> [TransitStop] {
        guard !enabled.isEmpty else { return [] }
        let candidates = grid.stops(in: viewport.padded(by: padding))
        var rail: [TransitStop] = []
        var bus: [TransitStop] = []
        let showBus = enabled.contains(.bus) && viewport.latDelta <= busMaxLatDelta
        for stop in candidates {
            if stop.kinds.contains(where: { $0 != .bus && enabled.contains($0) }) {
                rail.append(stop)
            } else if showBus && stop.isServed(by: .bus) {
                bus.append(stop)
            }
        }
        let budget = busBudget(latDelta: viewport.latDelta)
        if bus.count > budget {
            let cLat = viewport.centerLat, cLon = viewport.centerLon
            let lonScale = cos(cLat * .pi / 180)
            func d2(_ s: TransitStop) -> Double {
                let dy = s.latitude - cLat, dx = (s.longitude - cLon) * lonScale
                return dx * dx + dy * dy
            }
            bus = Array(bus.sorted { d2($0) < d2($1) }.prefix(budget))
        }
        return rail + bus
    }

    /// Network lines of enabled kinds that overlap the padded viewport.
    static func visibleLines(_ lines: [TransitLine], viewport: GeoBox,
                             enabled: Set<TransitLayerKind>) -> [TransitLine] {
        let box = viewport.padded(by: padding)
        return lines.filter { enabled.contains($0.kind) && $0.bbox.intersects(box) }
    }
}
