import Foundation

/// The parts of a MOTIS `/api/v6/plan` response this app reads. Every other
/// key in the (large) payload is ignored so a server-side addition never
/// breaks decoding.
struct MotisPlanResponse: Decodable, Sendable {
    /// Transit itineraries, in the engine's order.
    var itineraries: [MotisItinerary] = []
    /// Door-to-door options with no transit (a walk or a cycle the whole way).
    var direct: [MotisItinerary] = []

    private enum CodingKeys: String, CodingKey { case itineraries, direct }

    init(itineraries: [MotisItinerary] = [], direct: [MotisItinerary] = []) {
        self.itineraries = itineraries
        self.direct = direct
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itineraries = try c.decodeIfPresent([MotisItinerary].self, forKey: .itineraries) ?? []
        direct = try c.decodeIfPresent([MotisItinerary].self, forKey: .direct) ?? []
    }

    /// Decoder for MOTIS payloads: ISO 8601 timestamps with or without
    /// fractional seconds (the server emits both depending on the field).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = MotisDateParser.parse(text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }
}

/// Parses ISO 8601 with and without fractional seconds. The two format
/// styles are value types and Sendable, so they are built once and shared;
/// a plan payload carries a few hundred dates.
enum MotisDateParser {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle().time(includingFractionalSeconds: true)

    static func parse(_ text: String) -> Date? {
        if let date = try? plain.parse(text) { return date }
        return try? fractional.parse(text)
    }
}

struct MotisItinerary: Decodable, Sendable {
    let duration: Int
    let startTime: Date
    let endTime: Date
    let transfers: Int
    let legs: [MotisLeg]

    init(duration: Int, startTime: Date, endTime: Date, transfers: Int, legs: [MotisLeg]) {
        self.duration = duration
        self.startTime = startTime
        self.endTime = endTime
        self.transfers = transfers
        self.legs = legs
    }
}

struct MotisLeg: Decodable, Sendable {
    /// MOTIS `Mode`: WALK, BIKE, BUS, TRAM, REGIONAL_RAIL, ...
    let mode: String
    let from: MotisPlace
    let to: MotisPlace
    let duration: Int
    let startTime: Date
    let endTime: Date
    let realTime: Bool?
    let routeShortName: String?
    let headsign: String?
    let tripId: String?
    let routeId: String?
    let displayName: String?
    let legGeometry: MotisPolyline
    let intermediateStops: [MotisPlace]?

    init(mode: String, from: MotisPlace, to: MotisPlace, duration: Int, startTime: Date, endTime: Date,
         realTime: Bool? = nil, routeShortName: String? = nil, headsign: String? = nil,
         tripId: String? = nil, routeId: String? = nil, displayName: String? = nil,
         legGeometry: MotisPolyline, intermediateStops: [MotisPlace]? = nil) {
        self.mode = mode
        self.from = from
        self.to = to
        self.duration = duration
        self.startTime = startTime
        self.endTime = endTime
        self.realTime = realTime
        self.routeShortName = routeShortName
        self.headsign = headsign
        self.tripId = tripId
        self.routeId = routeId
        self.displayName = displayName
        self.legGeometry = legGeometry
        self.intermediateStops = intermediateStops
    }
}

struct MotisPlace: Decodable, Sendable {
    let name: String
    let lat: Double
    let lon: Double
    /// Feed-prefixed id ("ie-transport-for-ireland_8220GA00387"); nil at an address.
    let stopId: String?
    let arrival: Date?
    let departure: Date?

    init(name: String, lat: Double, lon: Double, stopId: String? = nil,
         arrival: Date? = nil, departure: Date? = nil) {
        self.name = name
        self.lat = lat
        self.lon = lon
        self.stopId = stopId
        self.arrival = arrival
        self.departure = departure
    }
}

struct MotisPolyline: Decodable, Sendable {
    /// Google encoded polyline.
    let points: String
    /// Decimal places the encoding used; MOTIS sends 6 or 7. Defaults to 6.
    let precision: Int
    /// Number of points, when the server says.
    let length: Int?

    private enum CodingKeys: String, CodingKey { case points, precision, length }

    init(points: String, precision: Int = 6, length: Int? = nil) {
        self.points = points
        self.precision = precision
        self.length = length
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decodeIfPresent(String.self, forKey: .points) ?? ""
        precision = try c.decodeIfPresent(Int.self, forKey: .precision) ?? 6
        length = try c.decodeIfPresent(Int.self, forKey: .length)
    }
}
