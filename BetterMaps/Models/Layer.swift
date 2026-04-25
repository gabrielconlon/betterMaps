import Foundation
import SwiftData

enum LayerKind: String, CaseIterable, Identifiable {
    case places = "places"
    case waypointPath = "waypoints"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .places: return "Places"
        case .waypointPath: return "Waypoint Path"
        }
    }

    var systemImage: String {
        switch self {
        case .places: return "mappin.and.ellipse"
        case .waypointPath: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    var description: String {
        switch self {
        case .places: return "Pins for spots you want to remember"
        case .waypointPath: return "Connects points into a route by nearest neighbors"
        }
    }
}

@Model
final class Layer {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#FF3B30"
    var symbolName: String = "mappin"
    var isVisible: Bool = true
    var isFavorite: Bool = false
    var sortOrder: Int = 0
    /// Persists `LayerKind.rawValue`. Defaulted to "places" for back-compat with existing layers.
    var kindRaw: String = LayerKind.places.rawValue
    /// Stroke width used when this layer renders as a waypoint path.
    var lineWidth: Double = 4.0
    var places: [Place]? = []
    var createdAt: Date = Date()

    var kind: LayerKind {
        get { LayerKind(rawValue: kindRaw) ?? .places }
        set { kindRaw = newValue.rawValue }
    }

    init(
        name: String = "",
        colorHex: String = "#FF3B30",
        symbolName: String = "mappin",
        sortOrder: Int = 0,
        kind: LayerKind = .places,
        lineWidth: Double = 4.0
    ) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.kindRaw = kind.rawValue
        self.lineWidth = lineWidth
        self.createdAt = Date()
    }
}
