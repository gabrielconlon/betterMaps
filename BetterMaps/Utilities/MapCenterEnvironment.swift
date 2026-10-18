import SwiftUI
import CoreLocation

private struct MapCenterKey: EnvironmentKey {
    static let defaultValue: CLLocationCoordinate2D? = nil
}

extension EnvironmentValues {
    /// Settled centre of the main map, for forms that start a new place
    /// "here" (`PlaceFormView(mapCenter:)`). `nil` outside `MapScreen`.
    var mapCenter: CLLocationCoordinate2D? {
        get { self[MapCenterKey.self] }
        set { self[MapCenterKey.self] = newValue }
    }
}
