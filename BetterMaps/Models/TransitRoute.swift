import Foundation

/// One GTFS route from the bundled `transit_routes.json` (also the row shape
/// `BusTimetableService.routes(forStop:)` returns).
struct TransitRoute: Codable, Sendable, Hashable, Identifiable {
    /// GTFS route_id.
    let id: String
    /// Short name, e.g. "39A", "Red", "DART".
    let short: String
    /// Long name, e.g. "Ongar - UCD".
    let long: String
    /// GTFS route_type: 0 tram (Luas), 2 rail (DART/commuter), 3 bus.
    let type: Int

    init(id: String, short: String, long: String, type: Int) {
        self.id = id
        self.short = short
        self.long = long
        self.type = type
    }

    private enum CodingKeys: String, CodingKey { case id, short, long, type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  short: try c.decodeIfPresent(String.self, forKey: .short) ?? "",
                  long: try c.decodeIfPresent(String.self, forKey: .long) ?? "",
                  type: try c.decode(Int.self, forKey: .type))
    }

    var kind: TransitLayerKind {
        switch type {
        case 0: return .luas
        case 2: return short.localizedCaseInsensitiveContains("DART") ? .dart : .rail
        default: return .bus
        }
    }
}
