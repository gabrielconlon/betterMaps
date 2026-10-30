import SwiftUI
import MapKit
import Observation

// MARK: - Active Sheet Enum (single-sheet pattern)

enum ActiveSheet: Identifiable {
    case placeDetail(Place)
    case poiDetail(MKMapItem)
    /// A tap on the map: the sheet opens at once and looks up the place there.
    case poiLookup(CLLocationCoordinate2D)
    /// New place form. `nil` coordinate starts the pin at the map centre;
    /// `name` and `layerId` prefill it (from the quick-add sheet).
    case newPlace(CLLocationCoordinate2D?, name: String? = nil, layerId: UUID? = nil)
    /// Long-press fast capture: name + one-tap "Add to <layer>".
    case quickAdd(CLLocationCoordinate2D)
    case transitArrivals(TransitStop)
    case layerDetail(UUID)
    /// New tag (`.places`) or trail group (`.waypointPath`).
    case newLayer(LayerKind)
    case editLayer(UUID)
    case trailDetail(UUID)
    case settings
    /// Public transport directions to `destination`. One fixed id: a new
    /// destination re-plans inside the open sheet instead of re-presenting.
    case directions(destination: DirectionsEndpoint)

    var id: String {
        switch self {
        case .placeDetail(let place): return "place-\(place.id)"
        case .poiDetail(let item): return "poi-\(item.name ?? "unknown")-\(item.placemark.coordinate.latitude)"
        case .poiLookup(let c): return "poiLookup-\(c.latitude),\(c.longitude)"
        case .newPlace: return "newPlace"
        case .quickAdd(let c): return "quickAdd-\(c.latitude),\(c.longitude)"
        case .transitArrivals(let stop): return "transit-\(stop.id)"
        case .layerDetail(let id): return "layer-\(id)"
        case .newLayer(let kind): return "newLayer-\(kind.rawValue)"
        case .editLayer(let id): return "editLayer-\(id)"
        case .trailDetail(let id): return "trail-\(id)"
        case .settings: return "settings"
        case .directions: return "directions"
        }
    }

    /// A card about something on the map (stop, place, trail), shown at a
    /// peek height with the map still live behind it. Forms and management
    /// screens are not: they hold edits a stray click must not throw away.
    /// On the Mac these get a close button, Escape, and click-the-map to close
    /// (see `MapCardCloseButton`), because there is no swipe down.
    var isMapCard: Bool {
        switch self {
        case .placeDetail, .poiDetail, .poiLookup, .transitArrivals, .trailDetail:
            return true
        case .newPlace, .quickAdd, .layerDetail, .newLayer, .editLayer, .settings:
            return false
        }
    }
}

/// A request to open the trail editor. `layerId` is the trail layer the user
/// started from (a LayerCard "Draw" button); `nil` when started from the
/// sheet's "+" menu, where MapScreen picks or creates the layer before
/// presenting. `trailId` edits an existing trail; `resuming` reopens a kept
/// draft.
struct DrawTrailRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let layerId: UUID?
    let trailId: UUID?
    let resuming: TrailDraft?

    init(layerId: UUID?, trailId: UUID? = nil, resuming: TrailDraft? = nil) {
        self.id = UUID()
        self.layerId = layerId
        self.trailId = trailId
        self.resuming = resuming
    }
}

@Observable
@MainActor
class MapViewModel {
    var selectedPlace: Place?
    var activeSheet: ActiveSheet?
    var longPressCoordinate: CLLocationCoordinate2D?
    /// Non-nil while the trail editor is open. MapScreen clears it when the
    /// editor finishes.
    var drawTrailRequest: DrawTrailRequest?

    func selectPlace(_ place: Place) {
        selectedPlace = place
        activeSheet = .placeDetail(place)
    }

    func showPOI(_ mapItem: MKMapItem) {
        activeSheet = .poiDetail(mapItem)
    }

    func lookUpPlace(at coordinate: CLLocationCoordinate2D) {
        activeSheet = .poiLookup(coordinate)
    }

    func startNewPlace(at coordinate: CLLocationCoordinate2D?) {
        longPressCoordinate = coordinate
        activeSheet = .newPlace(coordinate)
    }

    /// Long-press capture: the quick-add sheet for a dropped pin.
    func startQuickAdd(at coordinate: CLLocationCoordinate2D) {
        longPressCoordinate = coordinate
        activeSheet = .quickAdd(coordinate)
    }

    func showTransitArrivals(for stop: TransitStop) {
        activeSheet = .transitArrivals(stop)
    }

    func showLayerDetail(_ layerId: UUID) {
        activeSheet = .layerDetail(layerId)
    }

    /// Opens (or re-targets) the directions sheet.
    func showDirections(to destination: DirectionsEndpoint) {
        activeSheet = .directions(destination: destination)
    }

    /// A trail was tapped (map hit-test or list row).
    func showTrailDetail(_ trailId: UUID) {
        activeSheet = .trailDetail(trailId)
    }

    /// Open the trail editor, optionally inside `layerId` / on `trailId`.
    func requestDrawTrail(in layerId: UUID?, trailId: UUID? = nil, resuming: TrailDraft? = nil) {
        drawTrailRequest = DrawTrailRequest(layerId: layerId, trailId: trailId, resuming: resuming)
    }

    var isQuickAddOpen: Bool {
        if case .quickAdd = activeSheet { return true }
        return false
    }

    func dismissSheet() {
        activeSheet = nil
    }
}
