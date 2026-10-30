import Foundation
import CoreLocation

/// Builds the Transitous (MOTIS v6) `/plan` request from a `JourneyRequest`.
/// Pure functions so the URL can be asserted item by item in tests. The
/// request's mode and walk overrides, when set, win over its preferences.
enum MotisQuery {
    static let baseURL = URL(string: "https://api.transitous.org/api/v6/plan")!

    /// Cycling the whole way is capped at 45 minutes so the bike option stays
    /// a real alternative rather than a two-hour slog.
    static let maxDirectBikeSeconds = 2700
    /// What "walk any distance" is sent as: 90 minutes, the most anyone
    /// would walk to a train rather than the engine's own default.
    static let noWalkLimitSeconds = 5400

    static func url(for request: JourneyRequest, base: URL = baseURL, numItineraries: Int = 5) -> URL {
        let prefs = request.preferences
        let walkSeconds = request.effectiveWalkToleranceSeconds ?? noWalkLimitSeconds
        var items: [URLQueryItem] = [
            URLQueryItem(name: "fromPlace", value: place(request.origin)),
            URLQueryItem(name: "toPlace", value: place(request.destination)),
            URLQueryItem(name: "time", value: timestamp(request.time)),
            URLQueryItem(name: "arriveBy", value: request.arriveBy ? "true" : "false"),
            URLQueryItem(name: "numItineraries", value: String(numItineraries)),
            URLQueryItem(name: "maxTransfers", value: String(prefs.maxTransfers)),
            URLQueryItem(name: "maxPreTransitTime", value: String(walkSeconds)),
            URLQueryItem(name: "maxPostTransitTime", value: String(walkSeconds)),
            URLQueryItem(name: "transitModes", value: transitModes(request.effectiveTransitModes)),
            URLQueryItem(name: "directModes", value: prefs.allowBikeDirect ? "WALK,BIKE" : "WALK"),
        ]
        if prefs.allowBikeDirect {
            items.append(URLQueryItem(name: "maxDirectTime", value: String(maxDirectBikeSeconds)))
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }

    /// MOTIS mode list for the enabled networks, in the stable order
    /// BUS,COACH,TRAM,RAIL. DART and Rail both ride the engine's single RAIL
    /// flag; `MotisMapper.itineraries` filters them apart afterwards. Empty
    /// when no transit mode is on.
    static func transitModes(_ modes: Set<TransitMode>) -> String {
        var result: [String] = []
        if modes.contains(.bus) { result += ["BUS", "COACH"] }
        if modes.contains(.luas) { result.append("TRAM") }
        if modes.contains(.dart) || modes.contains(.rail) { result.append("RAIL") }
        return result.joined(separator: ",")
    }

    /// "lat,lon" to six decimal places, always with a period.
    static func place(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), c.latitude, c.longitude)
    }

    /// ISO 8601 UTC without fractional seconds ("2026-11-03T08:36:00Z").
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Transitous asks every client to identify itself with a contact.
    static func userAgent(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "BetterMaps/\(version) (https://github.com/gabrielconlon/betterMaps; gabe.conlon@gmail.com)"
    }

    /// MOTIS prefixes GTFS ids with the feed tag ("ie-transport-for-ireland_8220GA00387");
    /// strips through the first underscore so the id matches `TransitStop.id`.
    static func localStopId(_ motisId: String) -> String {
        guard let underscore = motisId.firstIndex(of: "_") else { return motisId }
        return String(motisId[motisId.index(after: underscore)...])
    }
}
