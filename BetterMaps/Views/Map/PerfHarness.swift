#if DEBUG
import SwiftUI
import MapKit
import SwiftData
import QuartzCore
import os

/// DEBUG-only pan/zoom benchmark. Launch with `-PerfPan` (and optionally
/// `-PerfSeed` to insert sample places and trails into a near-empty store,
/// `-PerfVerbose` for per-step lines).
/// Turns every transit kind on, drives the main map's camera through a fixed
/// 20-step path over Dublin, and logs one `PERF …` line with frame and
/// store-settle timings. No UI.
@MainActor
enum PerfHarness {
    private static let log = Logger(subsystem: "CustomMapApp", category: "perf")

    private struct Step {
        let lat: Double
        let lon: Double
        let span: Double
    }

    /// Pans at ~0.15, a zoom out to ~0.6, a zoom in to ~0.03, then the DART
    /// coast from Howth to Bray.
    private static let path: [Step] = [
        Step(lat: 53.3498, lon: -6.2603, span: 0.15),
        Step(lat: 53.3600, lon: -6.3000, span: 0.15),
        Step(lat: 53.3300, lon: -6.2200, span: 0.15),
        Step(lat: 53.3500, lon: -6.2600, span: 0.6),
        Step(lat: 53.3000, lon: -6.2000, span: 0.6),
        Step(lat: 53.3498, lon: -6.2603, span: 0.15),
        Step(lat: 53.3450, lon: -6.2600, span: 0.03),
        Step(lat: 53.3400, lon: -6.2500, span: 0.03),
        Step(lat: 53.3500, lon: -6.2700, span: 0.03),
        Step(lat: 53.3430, lon: -6.2400, span: 0.03),
        Step(lat: 53.3880, lon: -6.0750, span: 0.05),
        Step(lat: 53.3920, lon: -6.1500, span: 0.05),
        Step(lat: 53.3640, lon: -6.2000, span: 0.05),
        Step(lat: 53.3300, lon: -6.2100, span: 0.05),
        Step(lat: 53.3100, lon: -6.1900, span: 0.05),
        Step(lat: 53.2940, lon: -6.1350, span: 0.05),
        Step(lat: 53.2770, lon: -6.1000, span: 0.05),
        Step(lat: 53.2030, lon: -6.1000, span: 0.05),
        Step(lat: 53.3000, lon: -6.2000, span: 0.3),
        Step(lat: 53.3498, lon: -6.2603, span: 0.15),
    ]

    private static let stepDuration: Duration = .milliseconds(1200)
    private static let settleTimeout: Duration = .seconds(6)

    static func runIfRequested(camera: Binding<MapCameraPosition>,
                               contentStore: MapContentStore,
                               transitStore: TransitLayerStore,
                               settings: TransitLayerSettings,
                               modelContext: ModelContext) async {
        let args = ProcessInfo.processInfo.arguments
        // Seeding also works without the benchmark (UI tests use it alone).
        if args.contains("-PerfSeed") { seedIfNeeded(in: modelContext) }
        guard args.contains("-PerfPan") else { return }

        // Restored when the run ends so the user's transit settings survive.
        let previousKinds = settings.enabledKinds
        defer {
            for kind in TransitLayerKind.allCases {
                settings.setEnabled(previousKinds.contains(kind), for: kind)
            }
        }
        for kind in TransitLayerKind.allCases { settings.setEnabled(true, for: kind) }
        try? await Task.sleep(for: .seconds(3))
        // Give a slow bundle decode a little longer.
        var waited = 0
        while !transitStore.isLoaded && waited < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }

        let recorder = FrameRecorder()
        recorder.start()
        let clock = ContinuousClock()
        var settles: [Double] = []
        // `-PerfVerbose` adds a per-step breakdown before the summary line.
        let verbose = args.contains("-PerfVerbose")
        var frameMark = 0
        var previousIds = Set(transitStore.visibleStops.map(\.id))

        for step in path {
            let start = clock.now
            let mediaStart = CACurrentMediaTime()
            withAnimation(.easeInOut(duration: 0.6)) {
                camera.wrappedValue = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: step.lat, longitude: step.lon),
                    span: MKCoordinateSpan(latitudeDelta: step.span, longitudeDelta: step.span)))
            }
            // Settled = both stores finished a recompute that started after
            // the camera was set.
            var settledAt: ContinuousClock.Instant?
            while clock.now - start < settleTimeout {
                if let a = contentStore.debugLastSettle, a > start,
                   let b = transitStore.debugLastSettle, b > start {
                    settledAt = max(a, b)
                    break
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            settles.append(ms(settledAt.map { $0 - start } ?? settleTimeout))
            let elapsed = clock.now - start
            if elapsed < stepDuration { try? await Task.sleep(for: stepDuration - elapsed) }
            if verbose {
                let stepFrames = recorder.durationsMs[frameMark...]
                // "<duration>@<ms after the camera was set>"
                let hitches = stepFrames.indices.filter { stepFrames[$0] > 50 }.map {
                    "\(Int(stepFrames[$0]))@\(Int((recorder.endTimes[$0] - mediaStart) * 1000))"
                }
                let ids = Set(transitStore.visibleStops.map(\.id))
                print("PERFSTEP span=\(step.span) settleMs=\(Int(settles.last ?? 0)) maxFrameMs=\(Int(stepFrames.max() ?? 0)) hitches=\(hitches) stops=\(ids.count) added=\(ids.subtracting(previousIds).count) removed=\(previousIds.subtracting(ids).count) places=\(contentStore.output.places.count) clusters=\(contentStore.output.clusters.count)")
                frameMark = recorder.durationsMs.count
                previousIds = ids
            }
        }

        recorder.stop()
        let frames = recorder.durationsMs
        let line = String(format: "PERF frames=%d maxFrameMs=%.1f p95FrameMs=%.1f hitches>50ms=%d maxSettleMs=%.0f p95SettleMs=%.0f",
                          frames.count,
                          frames.max() ?? 0,
                          percentile(frames, 0.95),
                          frames.filter { $0 > 50 }.count,
                          settles.max() ?? 0,
                          percentile(settles, 0.95))
        log.notice("\(line, privacy: .public)")
        print(line)
    }

    private static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[idx]
    }

    // MARK: - Seed

    /// ~300 places over 3 place layers (every 5th also in a second layer)
    /// and 2 straight trails, only when the store holds fewer than 50 places.
    private static func seedIfNeeded(in context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Place>())) ?? 0
        guard count < 50 else { return }
        let colors = ["#FF9500", "#34C759", "#AF52DE"]
        let symbols = ["fork.knife", "cup.and.saucer.fill", "star.fill"]
        let layers = (0..<3).map { i in
            Layer(name: "Perf \(i + 1)", colorHex: colors[i], symbolName: symbols[i], sortOrder: 100 + i)
        }
        layers.forEach(context.insert)

        var rng = SystemRandomNumberGenerator()
        for i in 0..<300 {
            let place = Place(name: "Perf place \(i)",
                              latitude: 53.3498 + Double.random(in: -0.12...0.12, using: &rng),
                              longitude: -6.2603 + Double.random(in: -0.18...0.18, using: &rng))
            context.insert(place)
            var member = [layers[i % 3]]
            if i % 5 == 0 { member.append(layers[(i + 1) % 3]) }
            place.layers = member
        }

        let walks = Layer(name: "Perf walks", colorHex: "#007AFF", symbolName: "figure.walk",
                          sortOrder: 103, kind: .waypointPath)
        context.insert(walks)
        let routes: [[(Double, Double)]] = [
            // Grand Canal, Portobello → Ringsend
            [(53.3305, -6.2650), (53.3320, -6.2570), (53.3333, -6.2500), (53.3345, -6.2420),
             (53.3365, -6.2360), (53.3390, -6.2330), (53.3410, -6.2290), (53.3420, -6.2240)],
            // Phoenix Park, Parkgate → Castleknock gate
            [(53.3490, -6.2960), (53.3530, -6.3060), (53.3560, -6.3180), (53.3590, -6.3290),
             (53.3620, -6.3400), (53.3650, -6.3500)],
        ]
        for (r, points) in routes.enumerated() {
            let pathId = UUID()
            for (n, point) in points.enumerated() {
                let wp = Place(name: "Waypoint", latitude: point.0, longitude: point.1)
                context.insert(wp)
                wp.pathId = pathId
                wp.sortIndex = n
                wp.isWaypointEndpoint = n == 0 || n == points.count - 1
                wp.layers = [walks]
            }
            let geometry = TrailGeometry.straight(through: points.map {
                CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)
            })
            let trail = Trail(pathId: pathId, name: "Perf trail \(r + 1)",
                              distanceMeters: geometry.totalMeters, layer: walks)
            trail.geometry = geometry
            context.insert(trail)
        }
        try? context.save()
        TrailSnapshotter.postChange()
    }
}

/// Records display-link frame intervals on the main run loop.
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private(set) var durationsMs: [Double] = []

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// `CACurrentMediaTime` at the end of each recorded frame.
    private(set) var endTimes: [CFTimeInterval] = []

    @objc private func tick(_ link: CADisplayLink) {
        if let last {
            durationsMs.append((link.timestamp - last) * 1000)
            endTimes.append(link.timestamp)
        }
        last = link.timestamp
    }
}
#endif
