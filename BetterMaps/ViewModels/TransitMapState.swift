import SwiftUI
import MapKit
import Observation

@Observable
@MainActor
class TransitMapState {
    var transitStops: [TransitStop] = []
    var showTransitStops: Set<TransitStop.TransitStopType> = []
    var luasRedShapeLines: [[CLLocationCoordinate2D]] = []
    var luasGreenShapeLines: [[CLLocationCoordinate2D]] = []
    var dartShapeLines: [[CLLocationCoordinate2D]] = []
    var railShapeLines: [[CLLocationCoordinate2D]] = []

    /// Luas stop IDs broken out by line, so the map view can tint Red-line pins
    /// red (matching the Red line stroke) and Green-line pins green. Without
    /// this, every Luas stop draws as Green even when it sits on the Red line.
    var luasRedStopIds: Set<String> = []
    var luasGreenStopIds: Set<String> = []

    /// Updated from MapTabView's onMapCameraChange so computed properties can filter by region.
    /// Seeded to a Dublin-wide default so stops/lines render immediately on first launch —
    /// otherwise nothing shows until the user first pans the map (onMapCameraChange fires
    /// only onEnd of an interaction, not on the initial camera setup).
    var mapRegion: MKCoordinateRegion? = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
    )

    // MARK: - Visible Subset Computed Properties

    /// Transit stops filtered by active types and current map region.
    /// Visible at ALL zoom levels (dots at far zoom, full pins at close zoom),
    /// matching how custom layer places behave.
    /// At far zoom, rail/tram stops are prioritized over bus to avoid overwhelming the map.
    var visibleTransitStops: [TransitStop] {
        guard !showTransitStops.isEmpty, let region = mapRegion else { return [] }
        let latDelta = region.span.latitudeDelta

        let wantsDart = showTransitStops.contains(.dart)
        let wantsRail = showTransitStops.contains(.rail)

        let filtered = transitStops
            .filter { stop in
                switch stop.type {
                case .dart:
                    guard wantsDart else { return false }
                case .rail, .suburban:
                    guard wantsRail else { return false }
                case .bus:
                    guard showTransitStops.contains(.bus) else { return false }
                default:
                    guard showTransitStops.contains(stop.type) else { return false }
                }
                return true
            }
            .filter { stop in
                abs(stop.latitude - region.center.latitude) < latDelta &&
                abs(stop.longitude - region.center.longitude) < region.span.longitudeDelta
            }

        // Scale limits by zoom — dots are cheap but 14K bus stops would overwhelm.
        // Every branch prioritizes rail/luas/dart over bus: there are ~150 of
        // them total in Dublin vs ~14k bus stops, and a flat prefix() over a
        // bus-dominated array would silently drop every rail and DART pin
        // before the cap was reached. The user reported missing purple rail
        // pins on visible rail lines at city zoom — that was the bug.
        if latDelta > 1.0 {
            // Country-wide: only rail/tram network, no bus
            return filtered.filter { $0.type != .bus }
        } else if latDelta > 0.3 {
            // Regional: all rail/tram + sampled bus
            let priority = filtered.filter { $0.type != .bus }
            let bus = Array(filtered.filter { $0.type == .bus }.prefix(150))
            return priority + bus
        } else {
            // City/neighborhood: keep every rail/luas/dart in view, then
            // backfill with bus up to a generous overall budget. Total
            // ceiling stays around ~600 even on dense maps.
            let priority = filtered.filter { $0.type != .bus }
            let bus = Array(filtered.filter { $0.type == .bus }.prefix(400))
            return priority + bus
        }
    }

    // MARK: - Helpers

    /// Check if a stop is within threshold meters of any existing stop (same type)
    func isNearExistingStop(_ stop: TransitStop, in stops: [TransitStop], thresholdMeters: Double) -> Bool {
        stops.contains { existing in
            WaypointGraph.meters(existing.coordinate, stop.coordinate) < thresholdMeters
        }
    }

    // MARK: - Transit Toggle Persistence

    func serializeTransitTypes(_ types: Set<TransitStop.TransitStopType>) -> String {
        types.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    func deserializeTransitTypes(_ string: String) -> Set<TransitStop.TransitStopType> {
        guard !string.isEmpty else { return [] }
        return Set(string.split(separator: ",").compactMap { TransitStop.TransitStopType(rawValue: String($0)) })
    }
}
