import Foundation
import CoreLocation
import os

/// Plans journeys through Transitous, the public MOTIS instance. Network
/// access goes through an injectable `Loader` so tests never touch the
/// network; the default loader is `URLSession.shared`.
actor MotisJourneyProvider: JourneyProvider {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Planning is slower than a live board; 20 s covers a cold Transitous
    /// query without leaving the sheet spinning through an outage.
    static let requestTimeout: TimeInterval = 20

    private let loader: Loader
    private let baseURL: URL
    private let userAgent: String

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "directions"
    )

    init(loader: Loader? = nil, baseURL: URL = MotisQuery.baseURL, bundle: Bundle = .main) {
        self.loader = loader ?? { request in try await URLSession.shared.data(for: request) }
        self.baseURL = baseURL
        self.userAgent = MotisQuery.userAgent(bundle: bundle)
    }

    func plan(_ request: JourneyRequest) async throws -> [Itinerary] {
        let url = MotisQuery.url(for: request, base: baseURL)
        var urlRequest = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(urlRequest)
        } catch is CancellationError {
            throw JourneyProviderError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw JourneyProviderError.cancelled
        } catch {
            Self.logger.error("plan request failed: \(String(describing: type(of: error)), privacy: .public) \((error as? URLError)?.code.rawValue ?? 0)")
            throw JourneyProviderError.unavailable(status: nil)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logger.error("plan HTTP \(http.statusCode)")
            throw http.statusCode == 429
                ? JourneyProviderError.rateLimited
                : JourneyProviderError.unavailable(status: http.statusCode)
        }

        let decoded: MotisPlanResponse
        do {
            decoded = try MotisPlanResponse.decoder().decode(MotisPlanResponse.self, from: data)
        } catch {
            Self.logger.error("plan decode failed: \(String(describing: type(of: error)), privacy: .public)")
            throw JourneyProviderError.decoding
        }

        // The engine's order is kept: `DirectionsViewModel` is the one ranker,
        // once the probes' answers have been merged with these.
        let itineraries = MotisMapper.itineraries(from: decoded, preferences: request.preferences,
                                                  transitModesOverride: request.transitModesOverride)
        Self.logger.info("plan ok: \(decoded.itineraries.count) transit + \(decoded.direct.count) direct -> \(itineraries.count) after filter")
        return itineraries
    }
}

/// Turns MOTIS DTOs into the app's `Itinerary`/`Leg` values.
enum MotisMapper {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "directions"
    )

    /// MOTIS modes that mean "a train of some kind".
    static let railModes: Set<String> = [
        "RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "HIGHSPEED_RAIL",
        "LONG_DISTANCE", "NIGHT_RAIL", "SUBWAY", "METRO",
    ]

    /// The engine has one RAIL flag; DART is told apart by name, the same
    /// rule `TransitRoute.kind` uses for the TFI feed. Nil for a mode the
    /// app has no network for (FERRY, CAR, RENTAL, ODM, AIRPLANE, …): an
    /// itinerary riding one is dropped rather than shown as a bus.
    static func mode(_ motis: String, routeShortName: String?, displayName: String?) -> TransitMode? {
        switch motis {
        case "WALK": return .walk
        case "BIKE": return .bike
        case "TRAM": return .luas
        case "BUS", "COACH": return .bus
        case _ where railModes.contains(motis):
            let name = routeShortName ?? displayName ?? ""
            return name.localizedCaseInsensitiveContains("DART") ? .dart : .rail
        default: return nil
        }
    }

    /// Nil when the leg's mode is unknown.
    static func leg(_ l: MotisLeg) -> Leg? {
        guard let mode = mode(l.mode, routeShortName: l.routeShortName, displayName: l.displayName) else { return nil }
        let stops: [IntermediateStop] = (l.intermediateStops ?? []).compactMap { place in
            guard let time = place.arrival ?? place.departure else { return nil }
            return IntermediateStop(name: place.name, time: time,
                                    stopId: place.stopId.map(MotisQuery.localStopId))
        }
        return Leg(
            id: "\(l.tripId ?? l.mode)|\(l.startTime.timeIntervalSince1970)|\(l.from.name)",
            mode: mode,
            routeShortName: mode.isTransit ? (l.routeShortName ?? l.displayName) : nil,
            headsign: l.headsign,
            fromName: l.from.name,
            toName: l.to.name,
            fromStopId: l.from.stopId.map(MotisQuery.localStopId),
            toStopId: l.to.stopId.map(MotisQuery.localStopId),
            start: l.startTime,
            end: l.endTime,
            durationSeconds: l.duration,
            coordinates: EncodedPolyline.decode(l.legGeometry.points, precision: l.legGeometry.precision),
            intermediateStops: stops,
            isRealtime: l.realTime ?? false
        )
    }

    /// De-dup key: the trips ridden plus start and end. The engine's own
    /// `id` is a cursor blob that differs between pages for the same journey.
    static func itineraryId(_ i: MotisItinerary) -> String {
        let trips = i.legs.map { $0.tripId ?? $0.mode }.joined(separator: "|")
        return "\(trips)|\(Int(i.startTime.timeIntervalSince1970))|\(Int(i.endTime.timeIntervalSince1970))"
    }

    /// Nil when any leg rides a mode the app does not know.
    static func itinerary(_ i: MotisItinerary) -> Itinerary? {
        var legs: [Leg] = []
        legs.reserveCapacity(i.legs.count)
        for motisLeg in i.legs {
            guard let mapped = leg(motisLeg) else { return nil }
            legs.append(mapped)
        }
        return Itinerary(
            id: itineraryId(i),
            legs: legs,
            start: i.startTime,
            end: i.endTime,
            durationSeconds: i.duration,
            transfers: i.transfers,
            walkSeconds: legs.filter { $0.mode == .walk }.reduce(0) { $0 + $1.durationSeconds },
            bikeSeconds: legs.filter { $0.mode == .bike }.reduce(0) { $0 + $1.durationSeconds }
        )
    }

    /// Transit itineraries followed by direct ones, de-duplicated by id (first
    /// wins), then anything that rides a network the user has switched off is
    /// dropped. The post-filter is what lets DART and Rail be toggled
    /// separately although the engine has a single RAIL flag. A request's
    /// `transitModesOverride` replaces the user's set for that one filter, so
    /// a rail-only probe keeps its rail answers whatever else is enabled.
    /// An itinerary with a leg of unknown mode is dropped too; the modes seen
    /// are logged once per plan, with how often each occurred.
    static func itineraries(from response: MotisPlanResponse,
                            preferences: DirectionsPreferencesSnapshot,
                            transitModesOverride: Set<TransitMode>? = nil) -> [Itinerary] {
        var seen: Set<String> = []
        var result: [Itinerary] = []
        var unknownModes: [String: Int] = [:]
        let allowed = transitModesOverride?.filter(\.isTransit) ?? preferences.allowedTransitModes
        for motis in response.itineraries + response.direct {
            guard let itinerary = itinerary(motis) else {
                for l in motis.legs where mode(l.mode, routeShortName: l.routeShortName, displayName: l.displayName) == nil {
                    unknownModes[l.mode, default: 0] += 1
                }
                continue
            }
            guard seen.insert(itinerary.id).inserted else { continue }
            guard itinerary.transitLegs.allSatisfy({ allowed.contains($0.mode) }) else { continue }
            result.append(itinerary)
        }
        if !unknownModes.isEmpty {
            let summary = unknownModes.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
            logger.notice("plan: dropped itineraries with unknown modes \(summary, privacy: .public)")
        }
        return result
    }
}
