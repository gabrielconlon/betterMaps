import Foundation
import CoreLocation
import os

/// Plans bike routes on BRouter's public community server (brouter.de).
///
/// Usage terms: the server is run by volunteers for fair, non-commercial use,
/// and the attribution "Routing by BRouter" must be shown wherever routes
/// appear. If usage grows, self-host BRouter and point `baseURL` at it.
///
/// Network access goes through an injectable `Loader` so tests never touch
/// the network; the default loader is `URLSession.shared`.
actor BRouterCyclingProvider: CyclingRouteProvider {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let requestTimeout: TimeInterval = 20

    private let loader: Loader
    private let baseURL: URL
    private let userAgent: String

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "directions"
    )

    init(loader: Loader? = nil,
         baseURL: URL = URL(string: "https://brouter.de/brouter")!,
         bundle: Bundle = .main) {
        self.loader = loader ?? { request in try await URLSession.shared.data(for: request) }
        self.baseURL = baseURL
        self.userAgent = MotisQuery.userAgent(bundle: bundle)
    }

    /// `lonlats` is lon,lat order with six decimals, in the POSIX locale.
    static func url(for request: CyclingRouteRequest, base: URL) -> URL {
        let lonlats = String(
            format: "%.6f,%.6f|%.6f,%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            request.origin.longitude, request.origin.latitude,
            request.destination.longitude, request.destination.latitude)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lonlats", value: lonlats),
            URLQueryItem(name: "profile", value: request.style.brouterProfile),
            URLQueryItem(name: "alternativeidx", value: "0"),
            URLQueryItem(name: "format", value: "geojson"),
        ]
        return components.url!
    }

    func route(_ request: CyclingRouteRequest) async throws -> Itinerary {
        let url = Self.url(for: request, base: baseURL)
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
            Self.logger.error("bike request failed: \(String(describing: type(of: error)), privacy: .public) \((error as? URLError)?.code.rawValue ?? 0)")
            throw JourneyProviderError.unavailable(status: nil)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logger.error("bike HTTP \(http.statusCode)")
            throw http.statusCode == 429
                ? JourneyProviderError.rateLimited
                : JourneyProviderError.unavailable(status: http.statusCode)
        }

        let track: BRouterTrack
        do {
            track = try BRouterTrack.parse(data)
        } catch {
            Self.logger.error("bike decode failed: \(String(describing: type(of: error)), privacy: .public)")
            throw JourneyProviderError.decoding
        }

        Self.logger.info("bike ok: \(track.coordinates.count) points, \(track.durationSeconds) s")
        return Self.itinerary(from: track, request: request)
    }

    private static func itinerary(from track: BRouterTrack, request: CyclingRouteRequest) -> Itinerary {
        let start = request.departure
        let end = start.addingTimeInterval(TimeInterval(track.durationSeconds))
        let posix = Locale(identifier: "en_US_POSIX")
        let rounded = [request.origin, request.destination]
            .map { String(format: "%.4f,%.4f", locale: posix, $0.latitude, $0.longitude) }
            .joined(separator: ";")
        let id = "bike|\(request.style.rawValue)|\(Int(start.timeIntervalSince1970))|\(rounded)"
        let leg = Leg(
            id: id,
            mode: .bike,
            fromName: "Start",
            toName: "Destination",
            start: start,
            end: end,
            durationSeconds: track.durationSeconds,
            coordinates: track.coordinates
        )
        return Itinerary(
            id: id,
            legs: [leg],
            start: start,
            end: end,
            durationSeconds: track.durationSeconds,
            transfers: 0,
            walkSeconds: 0,
            bikeSeconds: track.durationSeconds,
            reason: request.style == .quiet ? request.style.displayName : nil
        )
    }
}

// MARK: - GeoJSON

/// The parts of BRouter's GeoJSON response the app uses.
private struct BRouterTrack {
    let coordinates: [CLLocationCoordinate2D]
    let durationSeconds: Int

    enum ParseError: Error { case noFeature, tooFewPoints, badDuration }

    static func parse(_ data: Data) throws -> BRouterTrack {
        let collection = try JSONDecoder().decode(BRouterFeatureCollection.self, from: data)
        guard let feature = collection.features.first else { throw ParseError.noFeature }
        let coordinates = feature.geometry.coordinates.map(\.coordinate)
        guard coordinates.count >= 2 else { throw ParseError.tooFewPoints }
        let seconds = feature.properties.totalTime
        guard seconds.isFinite, seconds >= 0 else { throw ParseError.badDuration }
        return BRouterTrack(coordinates: coordinates, durationSeconds: Int(seconds.rounded()))
    }
}

private struct BRouterFeatureCollection: Decodable {
    let features: [BRouterFeature]
}

private struct BRouterFeature: Decodable {
    let geometry: BRouterGeometry
    let properties: BRouterProperties
}

private struct BRouterGeometry: Decodable {
    let coordinates: [BRouterPosition]
}

/// [lon, lat] or [lon, lat, ele]; elevation is ignored.
private struct BRouterPosition: Decodable {
    let longitude: Double
    let latitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        longitude = try container.decode(Double.self)
        latitude = try container.decode(Double.self)
    }
}

private struct BRouterProperties: Decodable {
    let totalTime: Double

    private enum CodingKeys: String, CodingKey {
        case totalTime = "total-time"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTime = try container.decodeFlexibleNumber(forKey: .totalTime)
    }
}

private extension KeyedDecodingContainer {
    /// BRouter sends numbers as strings ("1286"); accept either form.
    func decodeFlexibleNumber(forKey key: Key) throws -> Double {
        if let number = try? decode(Double.self, forKey: key) { return number }
        let text = try decode(String.self, forKey: key)
        guard let number = Double(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "not a number")
        }
        return number
    }
}
