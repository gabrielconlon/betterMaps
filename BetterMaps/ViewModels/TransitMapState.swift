import SwiftUI
import MapKit
import Observation

@Observable
@MainActor
class TransitMapState {
    nonisolated static let debounce: Duration = .milliseconds(120)

    var transitStops: [TransitStop] = [] {
        didSet {
            grid = StopGrid(stops: transitStops)
            scheduleVisibleRecompute()
        }
    }
    var showTransitStops: Set<TransitStop.TransitStopType> = [] {
        didSet { if showTransitStops != oldValue { scheduleVisibleRecompute() } }
    }
    var luasRedShapeLines: [[CLLocationCoordinate2D]] = []
    var luasGreenShapeLines: [[CLLocationCoordinate2D]] = []
    var dartShapeLines: [[CLLocationCoordinate2D]] = []
    var railShapeLines: [[CLLocationCoordinate2D]] = []

    /// Luas stop IDs broken out by line, so the map view can tint Red-line pins
    /// red (matching the Red line stroke) and Green-line pins green. Without
    /// this, every Luas stop draws as Green even when it sits on the Red line.
    var luasRedStopIds: Set<String> = []
    var luasGreenStopIds: Set<String> = []

    /// Updated from the map's settled camera so the visible subset can be
    /// filtered by region. Seeded to a Dublin-wide default so stops/lines
    /// render immediately on first launch.
    var mapRegion: MKCoordinateRegion? = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
    ) {
        didSet { scheduleVisibleRecompute() }
    }

    /// Transit stops filtered by active types and current map region.
    /// Stored, not computed: recomputed off-main (debounced 120 ms) whenever
    /// `transitStops`, `showTransitStops` or `mapRegion` change, so a body
    /// pass never walks ~14k stops.
    private(set) var visibleTransitStops: [TransitStop] = []

    @ObservationIgnored private var grid = StopGrid(stops: [])
    @ObservationIgnored private var visibleTask: Task<Void, Never>?

    // MARK: - Visible subset

    private func scheduleVisibleRecompute() {
        visibleTask?.cancel()
        guard !showTransitStops.isEmpty, let region = mapRegion else {
            visibleTransitStops = []
            return
        }
        let grid = grid
        let show = showTransitStops
        let box = GeoBox(region: region)
        visibleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Self.visibleStops(in: grid, region: box, show: show)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.visibleTransitStops = result
        }
    }

    /// Same filtering as the old computed property, but the region query
    /// only touches grid cells that overlap the viewport.
    /// At far zoom, rail/tram stops are prioritized over bus to avoid
    /// overwhelming the map.
    nonisolated static func visibleStops(in grid: StopGrid,
                                         region: GeoBox,
                                         show: Set<TransitStop.TransitStopType>) -> [TransitStop] {
        guard !show.isEmpty else { return [] }
        let latDelta = region.latDelta
        let wantsDart = show.contains(.dart)
        let wantsRail = show.contains(.rail)

        // The old query accepted |Δ| < span (i.e. a box twice the viewport).
        let query = GeoBox(minLat: region.centerLat - latDelta, maxLat: region.centerLat + latDelta,
                           minLon: region.centerLon - region.lonDelta, maxLon: region.centerLon + region.lonDelta)

        let filtered = grid.stops(in: query).filter { stop in
            switch stop.type {
            case .dart: return wantsDart
            case .rail, .suburban: return wantsRail
            case .bus: return show.contains(.bus)
            default: return show.contains(stop.type)
            }
        }

        // Scale limits by zoom — dots are cheap but 14K bus stops would overwhelm.
        // Every branch prioritizes rail/luas/dart over bus: there are ~150 of
        // them total in Dublin vs ~14k bus stops, and a flat prefix() over a
        // bus-dominated array would silently drop every rail and DART pin
        // before the cap was reached.
        let priority = filtered.filter { $0.type != .bus }
        if latDelta > 1.0 {
            // Country-wide: only rail/tram network, no bus
            return priority
        } else if latDelta > 0.3 {
            // Regional: all rail/tram + sampled bus
            return priority + Array(filtered.filter { $0.type == .bus }.prefix(150))
        } else {
            // City/neighborhood: keep every rail/luas/dart in view, then
            // backfill with bus up to a generous overall budget.
            return priority + Array(filtered.filter { $0.type == .bus }.prefix(400))
        }
    }

    // MARK: - Helpers

    /// Check if a stop is within threshold meters of any existing stop (same type)
    func isNearExistingStop(_ stop: TransitStop, in stops: [TransitStop], thresholdMeters: Double) -> Bool {
        stops.contains { existing in
            WaypointGraph.meters(existing.coordinate, stop.coordinate) < thresholdMeters
        }
    }

    // MARK: - Transit Toggle Persistence

    func serializeTransitTypes(_ types: Set<TransitStop.TransitStopType>) -> String {
        types.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    func deserializeTransitTypes(_ string: String) -> Set<TransitStop.TransitStopType> {
        guard !string.isEmpty else { return [] }
        return Set(string.split(separator: ",").compactMap { TransitStop.TransitStopType(rawValue: String($0)) })
    }
}

// MARK: - Spatial grid

/// Uniform 0.01° grid over the stop set. Built once per `transitStops`
/// assignment; a viewport query visits only the overlapping cells.
struct StopGrid: Sendable {
    static let cellSize = 0.01

    private struct Key: Hashable { let row: Int; let col: Int }
    private let cells: [Key: [TransitStop]]
    let count: Int

    init(stops: [TransitStop]) {
        var cells: [Key: [TransitStop]] = [:]
        for stop in stops {
            cells[Self.key(lat: stop.latitude, lon: stop.longitude), default: []].append(stop)
        }
        self.cells = cells
        self.count = stops.count
    }

    private static func key(lat: Double, lon: Double) -> Key {
        Key(row: Int((lat / cellSize).rounded(.down)), col: Int((lon / cellSize).rounded(.down)))
    }

    /// Stops strictly inside `box`, in grid-cell order.
    func stops(in box: GeoBox) -> [TransitStop] {
        guard !cells.isEmpty else { return [] }
        let lo = Self.key(lat: box.minLat, lon: box.minLon)
        let hi = Self.key(lat: box.maxLat, lon: box.maxLon)
        var out: [TransitStop] = []
        for row in lo.row...hi.row {
            for col in lo.col...hi.col {
                guard let bucket = cells[Key(row: row, col: col)] else { continue }
                for stop in bucket where box.contains(lat: stop.latitude, lon: stop.longitude) {
                    out.append(stop)
                }
            }
        }
        return out
    }
}
