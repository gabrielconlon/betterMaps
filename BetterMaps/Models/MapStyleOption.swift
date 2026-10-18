import SwiftUI
import MapKit

/// The base map style. Persisted by raw value under `@AppStorage("mapStyle")`.
enum MapStyleOption: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case muted = "Muted"
    case satellite = "Satellite"
    case hybrid = "Hybrid"

    static let storageKey = "mapStyle"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .standard: return "map"
        case .muted: return "map.fill"
        case .satellite: return "globe.europe.africa.fill"
        case .hybrid: return "square.3.layers.3d.top.filled"
        }
    }

    /// The style the map-chrome toggle switches to next:
    /// standard → hybrid → satellite → standard. Muted joins the cycle at hybrid.
    var next: MapStyleOption {
        switch self {
        case .standard, .muted: return .hybrid
        case .hybrid: return .satellite
        case .satellite: return .standard
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard:
            return .standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        case .muted:
            return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .all, showsTraffic: false)
        case .satellite:
            return .imagery(elevation: .realistic)
        case .hybrid:
            return .hybrid(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        }
    }
}
