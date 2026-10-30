import Foundation
import CoreLocation

/// What the user asked for: where, when, and how they like to travel.
///
/// The two overrides exist for the probes `DirectionsViewModel` runs beside
/// the main query: a rail-only pass and a no-walk-limit pass per network.
/// They replace the matching preference for one request without touching
/// what the user set.
struct JourneyRequest: Sendable {
    var origin: CLLocationCoordinate2D
    var destination: CLLocationCoordinate2D
    var time: Date
    /// When true, `time` is the latest acceptable arrival instead of the
    /// earliest departure.
    var arriveBy: Bool
    var preferences: DirectionsPreferencesSnapshot
    /// Networks to plan with instead of `preferences.allowedTransitModes`.
    var transitModesOverride: Set<TransitMode>? = nil
    /// Walk limit to plan with instead of `preferences.walkToleranceMinutes`;
    /// `DirectionsPreferencesSnapshot.noWalkLimit` (0) lifts the limit.
    var walkToleranceOverrideMinutes: Int? = nil

    init(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D,
         time: Date = Date(), arriveBy: Bool = false,
         preferences: DirectionsPreferencesSnapshot = .default,
         transitModesOverride: Set<TransitMode>? = nil,
         walkToleranceOverrideMinutes: Int? = nil) {
        self.origin = origin
        self.destination = destination
        self.time = time
        self.arriveBy = arriveBy
        self.preferences = preferences
        self.transitModesOverride = transitModesOverride
        self.walkToleranceOverrideMinutes = walkToleranceOverrideMinutes
    }

    /// The networks this request may ride: the override, else the
    /// preferences' transit modes.
    var effectiveTransitModes: Set<TransitMode> {
        transitModesOverride?.filter(\.isTransit) ?? preferences.allowedTransitModes
    }

    /// The walk limit this request plans with, in minutes; 0 means none.
    var effectiveWalkToleranceMinutes: Int {
        walkToleranceOverrideMinutes ?? preferences.walkToleranceMinutes
    }

    /// The walk limit this request plans with, in seconds; nil when there
    /// is none.
    var effectiveWalkToleranceSeconds: Int? {
        let minutes = effectiveWalkToleranceMinutes
        return minutes == DirectionsPreferencesSnapshot.noWalkLimit ? nil : minutes * 60
    }
}

/// Anything that can turn a `JourneyRequest` into itineraries: the Transitous
/// client in production, a canned fixture in tests.
protocol JourneyProvider: Sendable {
    func plan(_ request: JourneyRequest) async throws -> [Itinerary]
}

enum JourneyProviderError: Error, Equatable, Sendable {
    /// The service answered with an error status (or did not answer at all).
    case unavailable(status: Int?)
    case rateLimited
    case decoding
    case cancelled

    /// Plain, non-technical copy for the directions sheet. Empty for
    /// `cancelled`, which the user caused and should not be told about.
    var userMessage: String {
        switch self {
        case .unavailable: return "Directions are unavailable right now."
        case .rateLimited: return "Too many requests. Try again in a minute."
        case .decoding: return "Directions could not be read."
        case .cancelled: return ""
        }
    }
}
