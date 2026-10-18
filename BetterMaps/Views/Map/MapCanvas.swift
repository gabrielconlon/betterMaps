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

    let onTapPlace: (UUID) -> Void
    let onTapCluster: (ClusterLite) -> Void
    let onTapStop: (TransitStop) -> Void
    /// Single tap on empty map: screen point and its coordinate (nil if the
    /// proxy could not convert it).
    let onTap: (CGPoint, CLLocationCoordinate2D?) -> Void
    /// Long press on the map; same payload as `onTap`.
    let onLongPress: (CGPoint, CLLocationCoordinate2D?) -> Void
    /// Fires once when a camera gesture settles (keyboard dismissal, transit
    /// viewport refresh).
    let onCameraSettled: (MKCoordinateRegion) -> Void

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
                    onTap(screenPoint, proxy.convert(screenPoint, from: .local))
                }
                // Long-press to drop a pin at the press location.
                // SwiftUI's plain .onLongPressGesture has no location, so we sequence a
                // zero-distance DragGesture after a LongPressGesture to capture the screen
                // point, then convert it through the MapReader proxy.
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            guard case .second(true, let drag?) = value else { return }
                            onLongPress(drag.location, proxy.convert(drag.location, from: .local))
                        }
                )
                .onMapCameraChange(frequency: .continuous) { context in
                    store.region = context.region
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
