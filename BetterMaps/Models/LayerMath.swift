import Foundation
import SwiftData

// MARK: - Lightweight value snapshots
//
// `Layer` and `Place` are SwiftData models (main-actor bound, reference
// semantics). The filtering math below never needs the model objects — only
// a handful of fields — so it operates on these `Sendable` snapshots. That
// lets the math run anywhere (background tasks, tests without a container)
// and keeps `LayerMath` free of main-actor requirements.

struct LayerLite: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let symbolName: String
    let isVisible: Bool
    let kind: LayerKind
    let sortOrder: Int
    /// Pinned to the top of the layers panel.
    let isFavorite: Bool

    init(id: UUID, name: String, colorHex: String = "#FF3B30", symbolName: String = "mappin",
         isVisible: Bool = true, kind: LayerKind = .places, sortOrder: Int = 0, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.isVisible = isVisible
        self.kind = kind
        self.sortOrder = sortOrder
        self.isFavorite = isFavorite
    }
}

struct PlaceLite: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    /// Ids of every layer (tag or trail group) this place belongs to.
    let layerIds: [UUID]
    /// Mirrors `Place.isWaypointEndpoint`.
    let isEndpoint: Bool
    let pathId: UUID?
    let sortIndex: Int
    let createdAt: Date

    init(id: UUID, name: String, latitude: Double = 0, longitude: Double = 0, layerIds: [UUID] = [],
         isEndpoint: Bool = false, pathId: UUID? = nil, sortIndex: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.layerIds = layerIds
        self.isEndpoint = isEndpoint
        self.pathId = pathId
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// How a tag selection matches places.
enum TagMatch: String, CaseIterable, Identifiable, Sendable {
    /// A place shows when it has at least one selected tag.
    case any
    /// A place shows only when it has every selected tag.
    case all

    var id: String { rawValue }

    /// User-facing label ("Any" / "All"); the stored value is `rawValue`.
    var title: String {
        switch self {
        case .any: return "Any"
        case .all: return "All"
        }
    }
}

/// Everything that decides which saved places and trails are drawn: the tag
/// selection and the two always-available layer switches.
struct PlaceFilter: Sendable, Equatable {
    /// Selected tag ids (place-kind layers). Empty shows every place.
    var tagIds: Set<UUID> = []
    var match: TagMatch = .any
    /// The Places layer. Off hides every place pin, trail endpoints included.
    var showPlaces = true
    /// The Trails layer. Off hides every trail and its endpoints.
    var showTrails = true

    static let showAll = PlaceFilter()
}

/// A place that passed the filter, annotated with how many selected tags it
/// has and which layer styles its pin.
struct MatchedPlace: Sendable, Identifiable, Equatable {
    let place: PlaceLite
    /// Number of *selected* tags the place has. 0 with no selection and for
    /// a trail-only endpoint.
    let matchCount: Int
    /// The tag that colours the pin: the lowest-`sortOrder` selected tag the
    /// place has, or with no selection its lowest-`sortOrder` tag. A
    /// trail-only endpoint is styled by its trail group.
    let pinLayerId: UUID?
    /// Draw the overlap ring: Match Any with two or more selected tags. In
    /// Match All every shown place has every selected tag, so a ring would
    /// be noise.
    let showsOverlap: Bool
    var id: UUID { place.id }

    init(place: PlaceLite, matchCount: Int, pinLayerId: UUID?, showsOverlap: Bool = false) {
        self.place = place
        self.matchCount = matchCount
        self.pinLayerId = pinLayerId
        self.showsOverlap = showsOverlap
    }
}

// MARK: - LayerMath

/// Pure tag and layer filtering math. No SwiftData, no actors, no state.
///
/// Layers of kind `.places` are **tags** (many-to-many with places); layers
/// of kind `.waypointPath` are **trail groups**. A tag's `isVisible` no
/// longer filters anything: the selection in `PlaceFilter` does.
enum LayerMath {

    /// Ids of every tag (layer of kind `.places`).
    static func tagIds(_ layers: [LayerLite]) -> Set<UUID> {
        Set(layers.filter { $0.kind == .places }.map(\.id))
    }

    /// Ids of every trail group (layer of kind `.waypointPath`).
    static func trailGroupIds(_ layers: [LayerLite]) -> Set<UUID> {
        Set(layers.filter { $0.kind == .waypointPath }.map(\.id))
    }

    /// Ids of trail groups that are drawn: the group is visible and the
    /// Trails layer is on.
    static func visibleTrailLayerIds(_ layers: [LayerLite], showTrails: Bool = true) -> Set<UUID> {
        guard showTrails else { return [] }
        return Set(layers.filter { $0.kind == .waypointPath && $0.isVisible }.map(\.id))
    }

    /// The selection with ids of deleted (or non-tag) layers removed.
    static func effectiveSelection(_ filter: PlaceFilter, layers: [LayerLite]) -> Set<UUID> {
        filter.tagIds.isEmpty ? [] : filter.tagIds.intersection(tagIds(layers))
    }

    /// How many of `ids` the place belongs to.
    static func matchCount(_ place: PlaceLite, visible ids: Set<UUID>) -> Int {
        place.layerIds.reduce(0) { ids.contains($1) ? $0 + 1 : $0 }
    }

    /// Applies the tag filter and the layer switches.
    ///
    /// - Places layer off: nothing is returned.
    /// - No tags selected: every place shows, untagged ones included.
    /// - `.any`: places with at least one selected tag.
    /// - `.all`: places with every selected tag.
    /// - Untagged places are hidden while a selection exists.
    /// - Trail rule: a place whose layers are all trail groups is a trail
    ///   point, not a saved place. It is drawn only when it is an endpoint of
    ///   a visible trail group with the Trails layer on, whatever the tag
    ///   selection. Intermediate waypoints feed the polyline, not the pins.
    ///
    /// Input order is preserved.
    static func filter(_ places: [PlaceLite], layers: [LayerLite], filter: PlaceFilter) -> [MatchedPlace] {
        guard filter.showPlaces else { return [] }
        let tags = tagIds(layers)
        let trailGroups = trailGroupIds(layers)
        let selected = effectiveSelection(filter, layers: layers)
        let visibleTrails = visibleTrailLayerIds(layers, showTrails: filter.showTrails)
        let sortOrderById: [UUID: Int] = Dictionary(layers.map { ($0.id, $0.sortOrder) },
                                                    uniquingKeysWith: { first, _ in first })

        var result: [MatchedPlace] = []
        result.reserveCapacity(places.count)

        for place in places {
            let passesTags = passesTagRule(place, tags: tags, trailGroups: trailGroups,
                                           selected: selected, match: filter.match)
            let passesTrail = place.isEndpoint && matchCount(place, visible: visibleTrails) > 0
            guard passesTags || passesTrail else { continue }

            let selectedCount = matchCount(place, visible: selected)
            let pin = lowest(of: place, in: selected.isEmpty ? tags : selected, sortOrderById: sortOrderById)
                ?? lowest(of: place, in: tags, sortOrderById: sortOrderById)
                ?? lowest(of: place, in: visibleTrails, sortOrderById: sortOrderById)
            result.append(MatchedPlace(
                place: place,
                matchCount: selectedCount,
                pinLayerId: pin,
                showsOverlap: filter.match == .any && selectedCount >= 2
            ))
        }
        return result
    }

    /// Number of saved places the tag selection matches, ignoring the
    /// Places switch and trail endpoints (for "N places match").
    static func matchingPlaceCount(_ places: [PlaceLite], layers: [LayerLite], filter: PlaceFilter) -> Int {
        let tags = tagIds(layers)
        let trailGroups = trailGroupIds(layers)
        let selected = effectiveSelection(filter, layers: layers)
        return places.reduce(0) {
            passesTagRule($1, tags: tags, trailGroups: trailGroups, selected: selected, match: filter.match)
                ? $0 + 1 : $0
        }
    }

    /// The lowest-`sortOrder` tag (selected first) the place has.
    static func pinTag(for place: PlaceLite, layers: [LayerLite], filter: PlaceFilter) -> UUID? {
        let sortOrderById: [UUID: Int] = Dictionary(layers.map { ($0.id, $0.sortOrder) },
                                                    uniquingKeysWith: { first, _ in first })
        let selected = effectiveSelection(filter, layers: layers)
        let tags = tagIds(layers)
        return lowest(of: place, in: selected.isEmpty ? tags : selected, sortOrderById: sortOrderById)
            ?? lowest(of: place, in: tags, sortOrderById: sortOrderById)
    }

    // MARK: Private

    private static func passesTagRule(_ place: PlaceLite, tags: Set<UUID>, trailGroups: Set<UUID>,
                                      selected: Set<UUID>, match: TagMatch) -> Bool {
        let tagCount = matchCount(place, visible: tags)
        // Only in trail groups: a trail point, handled by the trail rule.
        if tagCount == 0, matchCount(place, visible: trailGroups) > 0 { return false }
        if selected.isEmpty { return true }
        let selectedCount = matchCount(place, visible: selected)
        switch match {
        case .any: return selectedCount > 0
        case .all: return selectedCount == selected.count
        }
    }

    private static func lowest(of place: PlaceLite, in ids: Set<UUID>, sortOrderById: [UUID: Int]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        return place.layerIds
            .filter { ids.contains($0) }
            .min { (sortOrderById[$0] ?? .max, $0.uuidString) < (sortOrderById[$1] ?? .max, $1.uuidString) }
    }
}

// MARK: - Snapshots from SwiftData models

extension LayerLite {
    @MainActor
    init(_ layer: Layer) {
        self.init(id: layer.id,
                  name: layer.name,
                  colorHex: layer.colorHex,
                  symbolName: layer.symbolName,
                  isVisible: layer.isVisible,
                  kind: layer.kind,
                  sortOrder: layer.sortOrder,
                  isFavorite: layer.isFavorite)
    }
}

extension PlaceLite {
    @MainActor
    init(_ place: Place) {
        self.init(id: place.id,
                  name: place.name,
                  latitude: place.latitude,
                  longitude: place.longitude,
                  layerIds: (place.layers ?? []).map(\.id),
                  isEndpoint: place.isWaypointEndpoint,
                  pathId: place.pathId,
                  sortIndex: place.sortIndex,
                  createdAt: place.createdAt)
    }
}
