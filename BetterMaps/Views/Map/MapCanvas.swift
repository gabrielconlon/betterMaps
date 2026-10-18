import SwiftUI
import MapKit

/// The `Map` itself plus its gesture plumbing. Renders only from
/// `store.output` and the value arrays it is handed; continuous camera
/// changes feed the store (region + size) and nothing else.
struct MapCanvas: View {
    @Binding var cameraPosition: MapCameraPosition
    let store: MapContentStore
    let layersById: [UUID: LayerLite]
    let mapStyle: MapStyle
    /// Shared with `MapChrome` so its standalone location button and compass
    /// drive this map.
    let mapScope: Namespace.ID
    let transit: TransitLayerContent.Inputs
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
    /// Every camera change while it moves (cancels in-flight tap lookups).
    var onCameraChange: (MKCoordinateRegion) -> Void = { _ in }
    /// Fires once when a camera gesture settles (keyboard dismissal, transit
    /// viewport refresh).
    let onCameraSettled: (MKCoordinateRegion) -> Void

    /// True once the current long press has fired, until the finger lifts.
    @State private var longPressFired = false

    var body: some View {
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $cameraPosition, scope: mapScope) {
                    UserAnnotation()
                    PlacesLayerContent(places: store.output.places,
                                       clusters: store.output.clusters,
                                       layersById: layersById,
                                       size: store.output.annotationSize,
                                       onTapPlace: onTapPlace,
                                       onTapCluster: onTapCluster)
                    TrailsLayerContent(trails: store.output.trails)
                    TransitLayerContent(stops: transit.stops,
                                        lines: transit.lines,
                                        highlightedRoute: transit.highlightedRoute,
                                        latitudeDelta: transit.latitudeDelta,
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
                .onMapCameraChange(frequency: .continuous) { context in
                    store.region = context.region
                    onCameraChange(context.region)
                    if store.mapSize != geo.size { store.mapSize = geo.size }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    onCameraSettled(context.region)
                }
                .onAppear {
                    store.mapSize = geo.size
                }
            }
        }
    }
}
