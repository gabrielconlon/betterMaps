import Foundation
import CoreLocation
import os

// MARK: - Irish Rail Models

struct IrishRailStation: Identifiable {
    let id: String           // StationCode
    let name: String
    let latitude: Double
    let longitude: Double
    let type: StationType    // DART, Mainline, Suburban

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum StationType: String {
        case dart = "D"
        case mainline = "M"
        case suburban = "S"
        case all = "A"

        var displayName: String {
            switch self {
            case .dart: return "DART"
            case .mainline: return "Mainline"
            case .suburban: return "Suburban"
            case .all: return "All"
            }
        }
    }
}

struct IrishRailArrival: Identifiable {
    let id = UUID()
    let trainCode: String
    let origin: String
    let destination: String
    let dueIn: Int              // minutes
    let expectedArrival: String
    let expectedDeparture: String
    let status: String
    let direction: String
    let trainType: String       // DART, Mainline, etc.
    let lastLocation: String
}

extension IrishRailStation {
    /// The station closest to `coordinate`, if it is within `radius`
    /// metres. The API's station order is alphabetical, so "first within
    /// range" can pick the wrong one where stations sit close together.
    static func nearest(to coordinate: CLLocationCoordinate2D,
                        in stations: [IrishRailStation],
                        within radius: CLLocationDistance = 800) -> IrishRailStation? {
        stations
            .map { ($0, WaypointGraph.meters($0.coordinate, coordinate)) }
            .filter { $0.1 < radius }
            .min { $0.1 < $1.1 }?
            .0
    }
}

// MARK: - Irish Rail Service

actor IrishRailService {
    /// The station list changes a few times a year; one fetch a day is plenty.
    static let stationCacheLifetime: TimeInterval = 24 * 60 * 60

    private let baseURL = "http://api.irishrail.ie/realtime/realtime.asmx"
    private let load: TransitFeed.Loader
    private let now: @Sendable () -> Date
    private let stationCache: StationCache

    /// Views create their own `IrishRailService()`, so by default every
    /// instance shares one process-wide station cache.
    init(
        load: @escaping TransitFeed.Loader = TransitFeed.urlSessionLoader,
        now: @escaping @Sendable () -> Date = { Date() },
        stationCache: StationCache = .shared
    ) {
        self.load = load
        self.now = now
        self.stationCache = stationCache
    }

    /// Station lists keyed by type, with the time each was fetched.
    final class StationCache: Sendable {
        static let shared = StationCache()
        private let entries = OSAllocatedUnfairLock<[IrishRailStation.StationType: (stations: [IrishRailStation], fetchedAt: Date)]>(initialState: [:])

        init() {}

        func get(_ type: IrishRailStation.StationType) -> (stations: [IrishRailStation], fetchedAt: Date)? {
            entries.withLock { $0[type] }
        }

        func set(_ type: IrishRailStation.StationType, _ stations: [IrishRailStation], at date: Date) {
            entries.withLock { $0[type] = (stations, date) }
        }
    }

    /// All stations, optionally filtered by type. Served from a 24 h cache;
    /// an empty or failed response is never cached.
    func stations(type: IrishRailStation.StationType = .all) async throws(TransitFeedError) -> [IrishRailStation] {
        if let cached = stationCache.get(type),
           now().timeIntervalSince(cached.fetchedAt) < Self.stationCacheLifetime {
            return cached.stations
        }
        let path = type == .all
            ? "getAllStationsXML"
            : "getAllStationsXML_WithStationType?StationType=\(type.rawValue)"
        guard let url = URL(string: "\(baseURL)/\(path)") else { throw .unavailable }
        let data = try await TransitFeed.fetch(url, feed: "irishrail.stations", using: load)
        let stations = IrishRailStationParser(data: data).parse()
        guard !stations.isEmpty else {
            TransitFeed.logger.error("irishrail.stations returned no stations")
            throw .unavailable
        }
        stationCache.set(type, stations, at: now())
        return stations
    }

    /// Real-time arrivals for a station. An empty list means no trains due.
    func arrivals(stationCode: String, withinMinutes: Int = 30) async throws(TransitFeedError) -> [IrishRailArrival] {
        var components = URLComponents(string: "\(baseURL)/getStationDataByCodeXML_WithNumMins")
        components?.queryItems = [
            URLQueryItem(name: "StationCode", value: stationCode),
            URLQueryItem(name: "NumMins", value: String(withinMinutes)),
        ]
        guard let url = components?.url else { throw .unavailable }
        let data = try await TransitFeed.fetch(url, feed: "irishrail.arrivals", using: load)
        return IrishRailArrivalParser(data: data).parse()
    }

    /// Non-throwing convenience: `[]` when the feed is unavailable.
    func fetchStations(type: IrishRailStation.StationType = .all) async -> [IrishRailStation] {
        (try? await stations(type: type)) ?? []
    }

    /// Non-throwing convenience: `[]` when the feed is unavailable.
    func fetchArrivals(stationCode: String, withinMinutes: Int = 30) async -> [IrishRailArrival] {
        (try? await arrivals(stationCode: stationCode, withinMinutes: withinMinutes)) ?? []
    }
}

// MARK: - Shared live-feed plumbing

/// The only error live transit feeds (Irish Rail, Luas) surface. Transport
/// details (URLError, HTTP status) go to the log, never to views.
enum TransitFeedError: Error, Equatable, Sendable {
    case unavailable
}

enum TransitFeed {
    typealias Loader = @Sendable (URL) async throws -> (Data, URLResponse)

    /// True when a feed status or service message reports a genuine
    /// disruption (cancelled, delayed, suspended...). Routine statuses
    /// ("En Route", "On time", "Operating normally") are not.
    static func isDisruption(_ text: String) -> Bool {
        let keywords = ["cancel", "delay", "disrupt", "suspend", "not running", "not in service"]
        let lower = text.lowercased()
        return keywords.contains { lower.contains($0) }
    }

    static let urlSessionLoader: Loader = { url in
        try await URLSession.shared.data(from: url)
    }

    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "transit"
    )

    /// Runs `load` and maps every failure (transport, non-2xx) to
    /// `TransitFeedError.unavailable`. Never logs response bodies.
    static func fetch(_ url: URL, feed: String, using load: Loader) async throws(TransitFeedError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(url)
        } catch {
            logger.error("\(feed, privacy: .public) request failed: \(String(describing: type(of: error)), privacy: .public) \((error as? URLError)?.code.rawValue ?? 0)")
            throw .unavailable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            logger.error("\(feed, privacy: .public) HTTP \(http.statusCode)")
            throw .unavailable
        }
        return data
    }
}

// MARK: - XML Parsers

class IrishRailStationParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var stations: [IrishRailStation] = []
    private var currentElement = ""
    private var currentCode = ""
    private var currentName = ""
    private var currentLat = ""
    private var currentLng = ""
    private var currentType = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> [IrishRailStation] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return stations
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "objStation" {
            currentCode = ""
            currentName = ""
            currentLat = ""
            currentLng = ""
            currentType = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch currentElement {
        case "StationCode": currentCode += trimmed
        case "StationDesc": currentName += trimmed
        case "StationLatitude": currentLat += trimmed
        case "StationLongitude": currentLng += trimmed
        case "StationType": currentType += trimmed
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "objStation" {
            if let lat = Double(currentLat), let lng = Double(currentLng) {
                let type = IrishRailStation.StationType(rawValue: currentType) ?? .mainline
                stations.append(IrishRailStation(
                    id: currentCode,
                    name: currentName,
                    latitude: lat,
                    longitude: lng,
                    type: type
                ))
            }
        }
        currentElement = ""
    }
}

class IrishRailArrivalParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var arrivals: [IrishRailArrival] = []
    private var currentElement = ""
    private var fields: [String: String] = [:]

    init(data: Data) {
        self.data = data
    }

    func parse() -> [IrishRailArrival] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return arrivals
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "objStationData" {
            fields = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fields[currentElement, default: ""] += trimmed
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "objStationData" {
            arrivals.append(IrishRailArrival(
                trainCode: fields["Traincode"] ?? "",
                origin: fields["Origin"] ?? "",
                destination: fields["Destination"] ?? "",
                dueIn: Int(fields["Duein"] ?? "0") ?? 0,
                expectedArrival: fields["Exparrival"] ?? "",
                expectedDeparture: fields["Expdepart"] ?? "",
                status: fields["Status"] ?? "",
                direction: fields["Direction"] ?? "",
                trainType: fields["Traintype"] ?? "",
                lastLocation: fields["Lastlocation"] ?? ""
            ))
        }
        currentElement = ""
    }
}
