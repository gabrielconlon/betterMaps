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

    init(id: UUID, name: String, colorHex: String = "#FF3B30", symbolName: String = "mappin",
         isVisible: Bool = true, kind: LayerKind = .places, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.isVisible = isVisible
        self.kind = kind
        self.sortOrder = sortOrder
    }
}

struct PlaceLite: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    /// Ids of every layer this place belongs to (visible or not).
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

/// A place that passed the layer filter, annotated with how many visible
/// *place* layers it belongs to and which layer should style its pin.
struct MatchedPlace: Sendable, Identifiable {
    let place: PlaceLite
    /// Number of visible place-kind layers the place is a member of.
    /// Trail layers never count. A trail-only endpoint has matchCount 0.
    let matchCount: Int
    /// The visible layer with the lowest `sortOrder` that the place is in.
    /// Place layers are preferred over trail layers so a pin that is both a
    /// saved place and a trail endpoint is styled as the place.
    let primaryLayerId: UUID?
    var id: UUID { place.id }
}

/// One row of the "shared by" legend: e.g. "Brunch + Favourites · 4".
struct LegendEntry: Sendable, Hashable, Identifiable {
    /// The visible place-layer ids this group is shared by, in sortOrder order.
    let layerIds: [UUID]
    /// Layer names joined with " + " in sortOrder order.
    let label: String
    let count: Int
    var id: String { layerIds.map(\.uuidString).joined(separator: "|") }
}

// MARK: - LayerMath

/// Pure layer-filtering math. No SwiftData, no actors, no state.
enum LayerMath {

    /// Ids of visible layers of kind `.places`.
    static func visiblePlaceLayerIds(_ layers: [LayerLite]) -> Set<UUID> {
        Set(layers.filter { $0.kind == .places && $0.isVisible }.map(\.id))
    }

    /// Ids of visible layers of kind `.waypointPath` (trails).
    static func visibleTrailLayerIds(_ layers: [LayerLite]) -> Set<UUID> {
        Set(layers.filter { $0.kind == .waypointPath && $0.isVisible }.map(\.id))
    }

    /// How many of `visible` the place belongs to.
    static func matchCount(_ place: PlaceLite, visible: Set<UUID>) -> Int {
        place.layerIds.reduce(0) { visible.contains($1) ? $0 + 1 : $0 }
    }

    /// Applies the layer filter.
    ///
    /// - `.union`: a place shows if it is in any visible place layer.
    /// - `.intersection`: a place shows if it is in *every* visible place layer.
    ///   Trail (waypoint-path) layers are never counted — turning on a trail
    ///   must not empty the map in intersection mode.
    /// - Trail rule (ported from MapTabView.filteredPlaces): a place whose only
    ///   visible memberships are trail layers is drawn only if it is an
    ///   endpoint. Intermediate waypoints feed the polyline, not the pin set.
    ///   A visible trail's endpoint always shows, in either mode.
    ///
    /// Input order is preserved.
    static func filter(_ places: [PlaceLite], layers: [LayerLite], mode: FilterMode) -> [MatchedPlace] {
        let placeIds = visiblePlaceLayerIds(layers)
        let trailIds = visibleTrailLayerIds(layers)
        guard !placeIds.isEmpty || !trailIds.isEmpty else { return [] }

        let sortOrderById: [UUID: Int] = Dictionary(layers.map { ($0.id, $0.sortOrder) },
                                                    uniquingKeysWith: { first, _ in first })

        var result: [MatchedPlace] = []
        result.reserveCapacity(places.count)

        for place in places {
            let placeMatches = matchCount(place, visible: placeIds)
            let trailMatches = matchCount(place, visible: trailIds)

            let passesPlaceRule: Bool
            switch mode {
            case .union:
                passesPlaceRule = placeMatches > 0
            case .intersection:
                passesPlaceRule = !placeIds.isEmpty && placeMatches == placeIds.count
            }
            let passesTrailRule = trailMatches > 0 && place.isEndpoint
            guard passesPlaceRule || passesTrailRule else { continue }

            result.append(MatchedPlace(
                place: place,
                matchCount: placeMatches,
                primaryLayerId: primaryLayer(for: place, placeIds: placeIds, trailIds: trailIds,
                                             sortOrderById: sortOrderById)
            ))
        }
        return result
    }

    /// Groups places shared by two or more visible place layers by their
    /// exact visible-membership set and returns the `limit` largest groups.
    /// Ties on count break by label so the output is deterministic.
    static func intersectionLegend(_ matched: [MatchedPlace], layers: [LayerLite], limit: Int = 3) -> [LegendEntry] {
        guard limit > 0 else { return [] }
        let placeIds = visiblePlaceLayerIds(layers)
        let visibleLayers = layers
            .filter { placeIds.contains($0.id) }
            .sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
        let orderIndex: [UUID: Int] = Dictionary(uniqueKeysWithValues: visibleLayers.enumerated().map { ($1.id, $0) })
        let nameById: [UUID: String] = Dictionary(uniqueKeysWithValues: visibleLayers.map { ($0.id, $0.name) })

        var counts: [[UUID]: Int] = [:]
        for m in matched where m.matchCount >= 2 {
            let key = Set(m.place.layerIds)
                .filter { placeIds.contains($0) }
                .sorted { (orderIndex[$0] ?? .max) < (orderIndex[$1] ?? .max) }
            guard key.count >= 2 else { continue }
            counts[key, default: 0] += 1
        }

        let entries = counts.map { ids, count in
            LegendEntry(layerIds: ids,
                        label: ids.compactMap { nameById[$0] }.joined(separator: " + "),
                        count: count)
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.label < rhs.label
        }
        return Array(entries.prefix(limit))
    }

    /// How many places are in *every* visible place layer. Trail layers
    /// never count. 0 when no place layer is visible.
    static func overlapCount(_ places: [PlaceLite], layers: [LayerLite]) -> Int {
        let placeIds = visiblePlaceLayerIds(layers)
        guard !placeIds.isEmpty else { return 0 }
        return places.reduce(0) { matchCount($1, visible: placeIds) == placeIds.count ? $0 + 1 : $0 }
    }

    /// In "Overlap only" mode with two or more visible place layers and no
    /// place in all of them, the number of those layers (for "No places in
    /// all 3 layers"). `nil` otherwise.
    static func emptyOverlapLayerCount(_ places: [PlaceLite], layers: [LayerLite], mode: FilterMode) -> Int? {
        guard mode == .intersection else { return nil }
        let count = visiblePlaceLayerIds(layers).count
        guard count >= 2, overlapCount(places, layers: layers) == 0 else { return nil }
        return count
    }

    // MARK: Private

    private static func primaryLayer(for place: PlaceLite,
                                     placeIds: Set<UUID>,
                                     trailIds: Set<UUID>,
                                     sortOrderById: [UUID: Int]) -> UUID? {
        func lowest(in visible: Set<UUID>) -> UUID? {
            place.layerIds
                .filter { visible.contains($0) }
                .min { (sortOrderById[$0] ?? .max, $0.uuidString) < (sortOrderById[$1] ?? .max, $1.uuidString) }
        }
        return lowest(in: placeIds) ?? lowest(in: trailIds)
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
                  sortOrder: layer.sortOrder)
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
