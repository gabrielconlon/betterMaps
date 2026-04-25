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

/// User's pinned transit routes (e.g. bus S8, S21, 39A) shown as quick-access
/// chips in the layers panel. Lives alongside `Layer` because it follows the
/// same favorite/sortOrder/persisted-via-SwiftData pattern.
@Model
final class FavoriteTransitRoute {
    /// GTFS route_id — the canonical identifier from the GTFS feed.
    /// Cannot use @Attribute(.unique) here: this app's ModelContainer is
    /// configured with cloudKitDatabase: .automatic, and CloudKit-mirrored
    /// SwiftData containers reject unique constraints with a
    /// loadIssueModelContainer fatal at startup. Dedup is enforced in
    /// MapTabView.toggleFavoriteRoute by checking existing favorites.
    var routeId: String = ""
    /// Display string for the chip label, e.g. "S8" or "39A".
    var shortName: String = ""
    /// Long-form description shown on long-press / accessibility, e.g.
    /// "Spencer Dock — UCD via City Centre". Cached so we don't need a SQLite
    /// query each time the chip strip renders.
    var longName: String = ""
    /// GTFS route_type: 0=tram (Luas), 2=rail (DART/Commuter), 3=bus.
    /// Drives the chip color and icon.
    var routeType: Int = 3
    /// User-defined order within the chip strip; new favorites get the
    /// largest existing sortOrder + 1.
    var sortOrder: Int = 0
    var addedAt: Date = Date()

    init(routeId: String, shortName: String, longName: String, routeType: Int, sortOrder: Int = 0) {
        self.routeId = routeId
        self.shortName = shortName
        self.longName = longName
        self.routeType = routeType
        self.sortOrder = sortOrder
        self.addedAt = Date()
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
