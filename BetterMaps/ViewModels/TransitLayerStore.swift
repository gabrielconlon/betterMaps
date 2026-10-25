import Foundation
import MapKit
import Observation
import os

/// Decoded contents of `Resources/Transit/*.json`.
struct TransitBundle: Sendable {
    var stops: [TransitStop]
    var lines: [TransitLine]
    var routes: [TransitRoute]

    struct URLs: Sendable {
        let stops: URL
        let lines: URL
        let routes: URL

        init?(bundle: Bundle) {
            guard let stops = bundle.url(forResource: "transit_stops", withExtension: "json"),
                  let lines = bundle.url(forResource: "transit_lines", withExtension: "json"),
                  let routes = bundle.url(forResource: "transit_routes", withExtension: "json") else { return nil }
            self.stops = stops
            self.lines = lines
            self.routes = routes
        }
    }

    private struct StopsFile: Decodable { let stops: [TransitStop] }
    private struct LinesFile: Decodable { let lines: [TransitLine] }
    private struct RoutesFile: Decodable { let routes: [TransitRoute] }

    /// Build date of the bundled stops file (`"built":"YYYY-MM-DD"` near its
    /// start), read from the first bytes only so Settings never decodes the
    /// whole bundle.
    static func builtDate(in bundle: Bundle) -> Date? {
        guard let url = bundle.url(forResource: "transit_stops", withExtension: "json"),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512),
              case let text = String(decoding: head, as: UTF8.self),
              let range = text.range(of: #""built":"(\d{4}-\d{2}-\d{2})""#, options: .regularExpression)
        else { return nil }
        let day = text[range].dropFirst(9).prefix(10)
        return BusTimetableService.isoDay(String(day))
    }

    static func load(_ urls: URLs) throws -> TransitBundle {
        let decoder = JSONDecoder()
        return TransitBundle(
            stops: try decoder.decode(StopsFile.self, from: Data(contentsOf: urls.stops)).stops,
            lines: try decoder.decode(LinesFile.self, from: Data(contentsOf: urls.lines)).lines,
            routes: try decoder.decode(RoutesFile.self, from: Data(contentsOf: urls.routes)).routes
        )
    }
}

/// The transit layer's data and its visible subset.
///
/// Stops, lines and routes come from the app bundle, decoded once off-main
/// on the first `loadIfNeeded()`. MapScreen only calls that while at least
/// one transit kind is enabled, so a user with transit off never pays for
/// the decode. `visibleStops` / `visibleLines` are recomputed off-main
/// (debounced 120 ms) whenever `region` or `enabledKinds` change.
@Observable
@MainActor
final class TransitLayerStore {
    static let shared = TransitLayerStore()

    nonisolated static let debounce: Duration = .milliseconds(120)
    private static let log = Logger(subsystem: "com.gabrielconlon.CustomMapApp", category: "transit")

    private(set) var stops: [TransitStop] = []
    private(set) var lines: [TransitLine] = []
    private(set) var routes: [TransitRoute] = []
    private(set) var isLoading = false
    private(set) var isLoaded = false

    /// Settled map region (set when a camera move ends); drives the visible
    /// subset. Not observed: views read `zoomBucket` and the visible arrays,
    /// never the raw region.
    @ObservationIgnored var region: MKCoordinateRegion {
        didSet { scheduleVisibleRecompute() }
    }

    /// Pin sizes for the span `visibleStops` was culled for. Assigned only
    /// when a size threshold is crossed.
    private(set) var zoomBucket: TransitZoomBucket

    /// Mirrors `TransitLayerSettings.enabledKinds` (MapScreen keeps them in step).
    var enabledKinds: Set<TransitLayerKind> = [] {
        didSet { if enabledKinds != oldValue { scheduleVisibleRecompute() } }
    }

    private(set) var visibleStops: [TransitStop] = []
    private(set) var visibleLines: [TransitLine] = []

    /// Bumped whenever anything the map draws changes (visible stops,
    /// lines, zoom bucket, highlighted route), so the map can coalesce this
    /// store's and `MapContentStore`'s publishes into one redraw.
    private(set) var version = 0

    /// Polylines (one per direction) of the route picked from a favorite chip.
    private(set) var highlightedRoute: [[CLLocationCoordinate2D]]?
    private(set) var highlightedRouteId: String?
    /// Short name ("MU1") for the map's clear-route chip; nil when the
    /// caller had none to give.
    private(set) var highlightedRouteLabel: String?

    @ObservationIgnored private(set) var grid = TransitSpatialGrid(stops: [])
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var visibleTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private let bundle: Bundle

    init(bundle: Bundle = .main,
         region: MKCoordinateRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))) {
        self.bundle = bundle
        self.region = region
        self.zoomBucket = TransitZoomBucket(latitudeDelta: region.span.latitudeDelta)
    }

    // MARK: - Loading

    /// Decodes the bundled JSON once. Concurrent callers share the same load.
    func loadIfNeeded() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        guard let urls = TransitBundle.URLs(bundle: bundle) else {
            Self.log.error("transit bundle JSON missing from app bundle")
            return
        }
        isLoading = true
        let task = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TransitBundle.load(urls) }
            }.value
            let elapsed = (clock.now - start).components
            let ms = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            guard let self else { return }
            switch result {
            case .success(let loaded):
                Self.log.debug("transit bundle decoded in \(ms) ms: \(loaded.stops.count) stops, \(loaded.lines.count) lines, \(loaded.routes.count) routes")
                self.apply(loaded)
            case .failure(let error):
                Self.log.error("transit bundle decode failed: \(error.localizedDescription)")
            }
            self.isLoading = false
        }
        loadTask = task
        await task.value
    }

    /// Installs a decoded bundle (also used by tests to skip the file read).
    func apply(_ loaded: TransitBundle) {
        grid = TransitSpatialGrid(stops: loaded.stops)
        stops = loaded.stops
        lines = loaded.lines
        routes = loaded.routes
        isLoaded = true
        scheduleVisibleRecompute()
    }

    // MARK: - Visible subset

    private func scheduleVisibleRecompute() {
        visibleTask?.cancel()
        guard isLoaded, !enabledKinds.isEmpty else {
            if !visibleStops.isEmpty || !visibleLines.isEmpty {
                visibleStops = []
                visibleLines = []
                version &+= 1
            }
            return
        }
        let grid = grid
        let lines = lines
        let enabled = enabledKinds
        let viewport = GeoBox(region: region)
        let bucket = TransitZoomBucket(latitudeDelta: region.span.latitudeDelta)
        visibleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let (stops, visibleLines) = await Task.detached(priority: .userInitiated) {
                (TransitViewportCuller.visibleStops(grid: grid, viewport: viewport, enabled: enabled),
                 TransitViewportCuller.visibleLines(lines, viewport: viewport, enabled: enabled))
            }.value
            guard !Task.isCancelled, let self else { return }
            // Publish only what changed: an unchanged pan must not
            // invalidate the map content. Everything lands in one turn (one
            // map pass); per-frame batching was measured to add a full-cost
            // map pass per batch.
            var changed = false
            if self.zoomBucket != bucket { self.zoomBucket = bucket; changed = true }
            if self.visibleStops != stops { self.visibleStops = stops; changed = true }
            if self.visibleLines != visibleLines { self.visibleLines = visibleLines; changed = true }
            if changed { self.version &+= 1 }
            #if DEBUG
            self.debugLastSettle = ContinuousClock.now
            #endif
        }
    }

    #if DEBUG
    /// When the last visible-subset recompute finished; `PerfHarness` only.
    @ObservationIgnored private(set) var debugLastSettle: ContinuousClock.Instant?
    #endif

    // MARK: - Lookups

    /// The stop to open for a map POI at `coordinate`: the nearest rail /
    /// Luas / DART stop within 400 m, else the nearest bus stop within 200 m.
    func nearestStop(to coordinate: CLLocationCoordinate2D) -> TransitStop? {
        grid.nearest(to: coordinate, within: 400, where: { $0.kind != .bus }).first
            ?? grid.nearest(to: coordinate, within: 200).first
    }

    /// The nearest stop drawn as a dot (dots ignore touches) within `meters`
    /// of a map tap, so tapping a far-zoom dot still opens its arrivals.
    func nearestDotStop(to coordinate: CLLocationCoordinate2D, within meters: Double) -> TransitStop? {
        let bucket = zoomBucket
        let dotIds = Set(visibleStops.lazy.filter { bucket.size(for: $0.kind) == .dot }.map(\.id))
        guard !dotIds.isEmpty else { return nil }
        return grid.nearest(to: coordinate, within: meters, where: { dotIds.contains($0.id) }).first
    }

    func stop(id: String) -> TransitStop? {
        stops.first { $0.id == id || $0.altIds.contains(id) }
    }

    // MARK: - Highlighted route

    /// Draws `routeId` (both directions) from the timetable; a second call
    /// with the same id clears it. Starts the timetable download when it is
    /// not on the device yet.
    func toggleHighlightedRoute(_ routeId: String, label: String? = nil) {
        highlightTask?.cancel()
        if highlightedRouteId == routeId {
            clearHighlightedRoute()
            return
        }
        highlightedRouteId = routeId
        highlightedRouteLabel = label
        highlightedRoute = nil
        version &+= 1
        highlightTask = Task { [weak self] in
            let service = BusTimetableService.shared
            if case .ready = await service.currentState() {
                // already on device
            } else {
                var ready = false
                for await state in await service.ensureAvailable() {
                    if case .ready = state { ready = true; break }
                    if case .failed = state { break }
                    if Task.isCancelled { break }
                }
                guard ready else { return }
            }
            var shapes: [[CLLocationCoordinate2D]] = []
            for dir in 0...1 {
                if let shape = try? await service.routeShape(routeId: routeId, dir: dir), shape.count > 1 {
                    shapes.append(shape)
                }
            }
            guard !Task.isCancelled, let self, self.highlightedRouteId == routeId else { return }
            self.highlightedRoute = shapes.isEmpty ? nil : shapes
            self.version &+= 1
        }
    }

    func clearHighlightedRoute() {
        highlightTask?.cancel()
        highlightedRouteId = nil
        highlightedRouteLabel = nil
        highlightedRoute = nil
        version &+= 1
    }
}
