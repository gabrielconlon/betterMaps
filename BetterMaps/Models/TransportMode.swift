import MapKit
import SwiftUI

enum TransportMode: String, CaseIterable, Identifiable {
    case driving = "driving"
    case cycling = "cycling"
    case walking = "walking"
    case transit = "transit"

    var id: String { rawValue }

    /// Modes that use MapKit directions (not cycling)
    static var mapKitModes: [TransportMode] {
        [.driving, .walking, .transit]
    }

    var mkTransportType: MKDirectionsTransportType? {
        switch self {
        case .driving: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        case .cycling: return nil  // Uses OpenRouteService instead
        }
    }

    var displayName: String {
        switch self {
        case .driving: return "Driving"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .transit: return "Transit"
        }
    }

    var systemImage: String {
        switch self {
        case .driving: return "car.fill"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        case .transit: return "bus.fill"
        }
    }

    var color: Color {
        switch self {
        case .driving: return .blue
        case .cycling: return .teal
        case .walking: return .green
        case .transit: return .orange
        }
    }
}
