import SwiftUI
import MapKit

/// The `Map` itself plus its gesture plumbing. Renders only from a coalesced
/// copy of `store.output` and the transit store's culled arrays. The stores
/// are fed once per camera move, when it ends — never per frame, so a
/// gesture rebuilds no annotation.
struct MapCanvas: View {
    @Binding var cameraPosition: MapCameraPosition
    let store: MapContentStore
    let layersById: [UUID: LayerLite]
    let mapStyle: MapStyle
    /// Shared with `MapChrome` so its standalone location button and compass
    /// drive this map.
    let mapScope: Namespace.ID
    /// Read here (not by the screen) so a transit publish only redraws the map.
    let transitStore: TransitLayerStore
    /// Long-press pin shown while the quick-add sheet is open.
    let droppedPin: CLLocationCoordinate2D?

    let onTapPlace: (UUID) -> Void
    let onTapCluster: (ClusterLite) -> Void
    let onTapStop: (TransitStop) -> Void
    /// Tap on one of Apple's own public-transport icons (a station or stop
    /// the base map draws). Ours can sit under it or under a neighbouring
    /// pin, as at Connolly, so the icon itself has to open the timetable.
    let onTapTransitFeature: (MapFeature) -> Void
    /// Single tap on empty map: screen point, its coordinate (nil if the
    /// proxy could not convert it) and the map proxy for screen-space hit
    /// testing (trails).
    let onTap: (CGPoint, CLLocationCoordinate2D?, MapProxy) -> Void
    /// Long press on the map, fired as soon as the press is recognised (not
    /// on release): screen point and coordinate.
    let onLongPress: (CGPoint, CLLocationCoordinate2D?) -> Void
    /// Fires once when a camera move settles, after `store.region` is set
    /// (keyboard dismissal, transit viewport refresh).
    let onCameraSettled: (MKCoordinateRegion) -> Void

    /// True once the current long press has fired, until the finger lifts.
    @State private var longPressFired = false
    /// What the `Map` draws: a coalesced copy of both stores (see
    /// `MapContentSync`). The body reads only this, never the stores, so the
    /// two stores' publishes after a camera move cost one map pass, not two.
    @State private var shown = MapCanvasContent()
    /// Settled camera heading for the bus stop direction arrows. Updated on
    /// settle like everything else here, so a rotation redraws them once.
    @State private var mapHeading: Double = 0
    /// Apple map feature the user just tapped. Only public-transport POIs are
    /// selectable, and the selection is handed off and cleared at once, so
    /// Apple's selected-icon state never lingers.
    @State private var selectedFeature: MapFeature?
    #if DEBUG
    /// Settled centre for the UI-test probe (`-UITestMapProbe` only).
    @State private var probeCenter = "none"
    #endif

    var body: some View {
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $cameraPosition, selection: $selectedFeature, scope: mapScope) {
                    UserAnnotation()
                    PlacesLayerContent(places: shown.output.places,
                                       clusters: shown.output.clusters,
                                       layersById: layersById,
                                       size: shown.output.annotationSize,
                                       onTapPlace: onTapPlace,
                                       onTapCluster: onTapCluster)
                    TrailsLayerContent(trails: shown.output.trails)
                    TransitLayerContent(stops: shown.stops,
                                        lines: shown.lines,
                                        highlightedRoute: shown.highlightedRoute,
                                        zoomBucket: shown.zoomBucket,
                                        mapHeading: mapHeading,
                                        onTapStop: onTapStop)
                    if let droppedPin {
                        Annotation("Dropped Pin", coordinate: droppedPin, anchor: .bottom) {
                            DroppedPinAnnotation()
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(mapStyle)
                .mapFeatureSelectionDisabled { $0.pointOfInterestCategory != .publicTransport }
                .onChange(of: selectedFeature) { _, feature in
                    guard let feature else { return }
                    selectedFeature = nil
                    onTapTransitFeature(feature)
                }
                // Intentionally NOT using .ignoresSafeArea(). Even when applied
                // to the Map alone, SwiftUI propagates the Map's larger frame
                // to its sibling overlays in a parent ZStack — which dragged
                // our layer-toggle button up behind the OS status bar.
                // Controls live in MapChrome (top-right stack) so they can
                // stay clear of the bottom sheet.
                .mapControls { }
                .onTapGesture { screenPoint in
                    onTap(screenPoint, proxy.convert(screenPoint, from: .local), proxy)
                }
                // Long-press to drop a pin at the press location.
                // SwiftUI's plain .onLongPressGesture has no location, so we sequence a
                // zero-distance DragGesture after a LongPressGesture to capture the screen
                // point, then convert it through the MapReader proxy. It fires on the
                // drag's first change — the moment the press is recognised — so the pin
                // and haptic land while the finger is still down.
                //
                // Must be `.simultaneousGesture`, not `.gesture`: attached with
                // `.gesture`, any `.onChanged` on this sequence (even an empty one)
                // stops one-finger drags from panning the map at all. Pinned by
                // `MapPanUITests.testOneFingerDragPansMap`.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onChanged { value in
                            guard !longPressFired, case .second(true, let drag?) = value else { return }
                            longPressFired = true
                            onLongPress(drag.location, proxy.convert(drag.location, from: .local))
                        }
                        .onEnded { value in
                            defer { longPressFired = false }
                            guard !longPressFired, case .second(true, let drag?) = value else { return }
                            onLongPress(drag.location, proxy.convert(drag.location, from: .local))
                        }
                )
                .onMapCameraChange(frequency: .onEnd) { context in
                    if store.mapSize != geo.size { store.mapSize = geo.size }
                    store.region = context.region
                    // Only a real turn redraws the pins, not float noise.
                    if abs(context.camera.heading - mapHeading) >= 1 { mapHeading = context.camera.heading }
                    onCameraSettled(context.region)
                    #if DEBUG
                    if MapCenterProbe.isEnabled { probeCenter = MapCenterProbe.format(context.region.center) }
                    #endif
                }
                .onAppear {
                    store.mapSize = geo.size
                }
                .onChange(of: geo.size) { _, size in
                    store.mapSize = size
                }
            }
        }
        .background {
            MapContentSync(store: store, transitStore: transitStore, shown: $shown)
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if MapCenterProbe.isEnabled { MapCenterProbe(value: probeCenter) }
        }
        #endif
    }
}

#if DEBUG
/// UI-test probe: an invisible, untouchable 1×1 accessibility element whose
/// value is the settled map centre ("lat,lon", 4 decimals). Present only
/// when launched with `-UITestMapProbe`.
struct MapCenterProbe: View {
    let value: String

    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-UITestMapProbe")

    static func format(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", c.latitude, c.longitude)
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Map centre")
            .accessibilityIdentifier("debug.mapCenter")
            .accessibilityValue(value)
    }
}
#endif

/// Value snapshot of everything the map content draws.
struct MapCanvasContent {
    var output: CullOutput = .empty
    var stops: [TransitStop] = []
    var lines: [TransitLine] = []
    var highlightedRoute: [[CLLocationCoordinate2D]]?
    var zoomBucket = TransitZoomBucket(latitudeDelta: 0.2)

    @MainActor
    init() {}

    @MainActor
    init(_ store: MapContentStore, _ transit: TransitLayerStore) {
        output = store.output
        stops = transit.visibleStops
        lines = transit.visibleLines
        highlightedRoute = transit.highlightedRoute
        zoomBucket = transit.zoomBucket
    }
}

/// Invisible observer of both stores' `version`s. When either changes it
/// waits `coalesceWindow` (restarting on a further change) and then copies
/// both stores into `shown` at once. Each map content pass re-syncs every
/// annotation, so one pass per settle instead of one per store halves the
/// hitches after a camera move.
private struct MapContentSync: View {
    let store: MapContentStore
    let transitStore: TransitLayerStore
    @Binding var shown: MapCanvasContent

    static let coalesceWindow: Duration = .milliseconds(40)

    private struct Versions: Equatable {
        let places: Int
        let transit: Int
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: Versions(places: store.version, transit: transitStore.version)) {
                try? await Task.sleep(for: Self.coalesceWindow)
                guard !Task.isCancelled else { return }
                shown = MapCanvasContent(store, transitStore)
            }
    }
}
