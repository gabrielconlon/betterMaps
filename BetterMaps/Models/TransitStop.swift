import Foundation
import CoreLocation

/// One stop from the bundled `transit_stops.json` (see scripts/README.md).
///
/// `kind` is the highest-priority network serving the stop
/// (`dart > rail > luas > bus`); `kinds` lists every network when a stop is
/// shared (Connolly is `dart` + `rail`). `altIds` are GTFS stop ids merged
/// into this one (the second Luas platform); departures for the stop are the
/// union over `id` and `altIds`.
struct TransitStop: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let kind: TransitLayerKind
    /// Public plate number (bus stops only).
    let code: String?
    /// `"red"` / `"green"` for Luas stops.
    let line: String?
    let altIds: [String]
    /// Every network serving the stop; `[kind]` for single-network stops.
    let kinds: [TransitLayerKind]
    /// Bus stops only: the direction buses leave in, degrees clockwise from
    /// north, read off the departing trips' shapes. nil when they leave in
    /// different directions (a terminus loop) or the feed has no shape. Buses
    /// drive on the left, so this also says which side of the road it is.
    let heading: Int?
    /// Bus stops only: the most common destination (GTFS headsign) of the
    /// buses leaving here.
    let toward: String?

    init(id: String, name: String, latitude: Double, longitude: Double,
         kind: TransitLayerKind, code: String? = nil, line: String? = nil,
         altIds: [String] = [], kinds: [TransitLayerKind]? = nil,
         heading: Int? = nil, toward: String? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.kind = kind
        self.code = code
        self.line = line
        self.altIds = altIds
        self.kinds = kinds ?? [kind]
        self.heading = heading
        self.toward = toward
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// `id` followed by `altIds`: every GTFS stop id this pin stands for.
    var allIds: [String] { [id] + altIds }

    func isServed(by kind: TransitLayerKind) -> Bool { kinds.contains(kind) }

    /// Visible when any network serving it is enabled.
    func isVisible(in enabled: Set<TransitLayerKind>) -> Bool {
        kinds.contains { enabled.contains($0) }
    }

    /// "north-east" etc. for `heading`, nil without one.
    var headingName: String? {
        guard let heading else { return nil }
        let names = ["north", "north-east", "east", "south-east",
                     "south", "south-west", "west", "north-west"]
        return names[Int((Double(heading) / 45).rounded()) % 8]
    }

    // MARK: - Codable (bundle keys: id,name,lat,lon,kind,code,line,altIds,kinds,brg,to)

    private enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, kind, code, line, altIds, kinds, brg, to
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(TransitLayerKind.self, forKey: .kind)
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  latitude: try c.decode(Double.self, forKey: .lat),
                  longitude: try c.decode(Double.self, forKey: .lon),
                  kind: kind,
                  code: try c.decodeIfPresent(String.self, forKey: .code),
                  line: try c.decodeIfPresent(String.self, forKey: .line),
                  altIds: try c.decodeIfPresent([String].self, forKey: .altIds) ?? [],
                  kinds: try c.decodeIfPresent([TransitLayerKind].self, forKey: .kinds),
                  heading: try c.decodeIfPresent(Int.self, forKey: .brg),
                  toward: try c.decodeIfPresent(String.self, forKey: .to))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(latitude, forKey: .lat)
        try c.encode(longitude, forKey: .lon)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(line, forKey: .line)
        if !altIds.isEmpty { try c.encode(altIds, forKey: .altIds) }
        if kinds.count > 1 { try c.encode(kinds, forKey: .kinds) }
        try c.encodeIfPresent(heading, forKey: .brg)
        try c.encodeIfPresent(toward, forKey: .to)
    }
}
