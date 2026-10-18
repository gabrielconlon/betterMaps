import SwiftUI
import MapKit

/// Opened the moment the user taps the map away from any pin, stop or trail:
/// shows a loading line while the nearest place is looked up, then the place
/// (`POIAddToLayerView`) or an empty state. Nothing floats over the map.
struct POILookupSheet: View {
    let coordinate: CLLocationCoordinate2D
    let onDismiss: () -> Void

    private enum Phase {
        case loading
        case found(MKMapItem)
        case nothing
    }

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                StatusView(status: .loading("Finding place…"))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityAddTraits(.updatesFrequently)
            case .found(let item):
                POIAddToLayerView(mapItem: item, onDismiss: onDismiss)
            case .nothing:
                StatusView(status: .empty(title: "Nothing here",
                                          hint: "Long-press to save a spot.",
                                          systemImage: "mappin.slash",
                                          action: nil))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task {
            let item = await POILookup.nearestItem(to: coordinate)
            guard !Task.isCancelled else { return }
            phase = item.map(Phase.found) ?? .nothing
        }
    }
}
