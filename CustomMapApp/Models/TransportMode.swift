import MapKit
import SwiftUI

enum TransportMode: String, CaseIterable, Identifiable {
    case driving = "driving"
    case walking = "walking"
    case transit = "transit"

    var id: String { rawValue }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .driving: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        }
    }

    var displayName: String {
        switch self {
        case .driving: return "Driving"
        case .walking: return "Walking"
        case .transit: return "Transit"
        }
    }

    var systemImage: String {
        switch self {
        case .driving: return "car.fill"
        case .walking: return "figure.walk"
        case .transit: return "bus.fill"
        }
    }

    var color: Color {
        switch self {
        case .driving: return .blue
        case .walking: return .green
        case .transit: return .orange
        }
    }
}
