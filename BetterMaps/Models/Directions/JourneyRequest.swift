import Foundation
import CoreLocation

/// What the user asked for: where, when, and how they like to travel.
struct JourneyRequest: Sendable {
    var origin: CLLocationCoordinate2D
    var destination: CLLocationCoordinate2D
    var time: Date
    /// When true, `time` is the latest acceptable arrival instead of the
    /// earliest departure.
    var arriveBy: Bool
    var preferences: DirectionsPreferencesSnapshot

    init(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D,
         time: Date = Date(), arriveBy: Bool = false,
         preferences: DirectionsPreferencesSnapshot = .default) {
        self.origin = origin
        self.destination = destination
        self.time = time
        self.arriveBy = arriveBy
        self.preferences = preferences
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
