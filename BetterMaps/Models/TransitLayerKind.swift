import Foundation

/// The four transit networks the map can draw as background infrastructure.
/// Key type for `TransitColors.layer(_:)`.
enum TransitLayerKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case bus
    case luas
    case dart
    case rail

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bus: return "Bus"
        case .luas: return "Luas"
        case .dart: return "DART"
        case .rail: return "Rail"
        }
    }

    var systemImage: String {
        switch self {
        case .bus: return "bus.fill"
        case .luas, .dart, .rail: return "tram.fill"
        }
    }
}
