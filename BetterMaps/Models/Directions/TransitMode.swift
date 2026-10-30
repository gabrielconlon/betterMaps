import Foundation

/// Every way a journey leg can move: the four transit networks the map
/// draws (see `TransitLayerKind`) plus walking and cycling, which have no
/// layer of their own.
enum TransitMode: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case bus
    case luas
    case dart
    case rail
    case walk
    case bike

    var id: String { rawValue }

    init(_ kind: TransitLayerKind) {
        switch kind {
        case .bus: self = .bus
        case .luas: self = .luas
        case .dart: self = .dart
        case .rail: self = .rail
        }
    }

    /// The map layer this mode rides on; nil for walk and bike.
    var layerKind: TransitLayerKind? {
        switch self {
        case .bus: return .bus
        case .luas: return .luas
        case .dart: return .dart
        case .rail: return .rail
        case .walk, .bike: return nil
        }
    }

    /// True for modes that board a vehicle on a timetable.
    var isTransit: Bool { layerKind != nil }

    var displayName: String {
        switch self {
        case .walk: return "Walk"
        case .bike: return "Bike"
        case .bus, .luas, .dart, .rail: return layerKind?.displayName ?? rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .bus, .luas, .dart, .rail: return layerKind?.systemImage ?? "questionmark"
        }
    }
}
