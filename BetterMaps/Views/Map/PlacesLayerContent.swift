import SwiftUI
import MapKit

/// Saved places and far-zoom clusters. Value inputs only.
struct PlacesLayerContent: MapContent {
    let places: [MatchedPlace]
    let clusters: [ClusterLite]
    let layersById: [UUID: LayerLite]
    let size: AnnotationSize
    let onTapPlace: (UUID) -> Void
    let onTapCluster: (ClusterLite) -> Void

    var body: some MapContent {
        ForEach(places) { matched in
            let layer = matched.pinLayerId.flatMap { layersById[$0] }
            let color = layer.flatMap { Color(hex: $0.colorHex) } ?? .red
            Annotation(size == .dot ? "" : matched.place.name,
                       coordinate: CLLocationCoordinate2D(latitude: matched.place.latitude,
                                                          longitude: matched.place.longitude)) {
                PlaceAnnotationView(color: color,
                                    symbol: layer?.symbolName ?? "mappin",
                                    name: matched.place.name,
                                    overlapCount: matched.showsOverlap ? matched.matchCount : 0,
                                    size: size)
                    .onTapGesture { onTapPlace(matched.place.id) }
            }
        }

        ForEach(clusters) { cluster in
            Annotation("", coordinate: cluster.coordinate) {
                ClusterBubble(cluster: cluster, onTap: onTapCluster)
            }
        }
    }
}
