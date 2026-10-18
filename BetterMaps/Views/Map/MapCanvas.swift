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

    var body: some View {
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $cameraPosition, scope: mapScope) {
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
                                        onTapStop: onTapStop)
                    if let droppedPin {
                        Annotation("Dropped Pin", coordinate: droppedPin, anchor: .bottom) {
                            DroppedPinAnnotation()
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(mapStyle)
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
                .gesture(
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
                    onCameraSettled(context.region)
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
    }
}

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
