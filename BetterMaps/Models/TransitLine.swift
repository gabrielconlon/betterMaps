import Foundation
import CoreLocation

/// One network polyline from the bundled `transit_lines.json`: a Luas line,
/// the DART, or an Irish Rail route (directions merged).
struct TransitLine: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let kind: TransitLayerKind
    /// `"red"` / `"green"` for Luas lines.
    let line: String?
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    /// Bounding box of `coordinates`, for viewport culling.
    let bbox: GeoBox

    init(id: String, kind: TransitLayerKind, line: String? = nil, name: String, coords: [[Double]]) {
        self.id = id
        self.kind = kind
        self.line = line
        self.name = name
        self.coordinates = coords.compactMap {
            $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
        }
        self.bbox = GeoBox(containing: coords) ?? GeoBox(minLat: 0, maxLat: 0, minLon: 0, maxLon: 0)
    }

    private enum CodingKeys: String, CodingKey { case id, kind, line, name, coords }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  kind: try c.decode(TransitLayerKind.self, forKey: .kind),
                  line: try c.decodeIfPresent(String.self, forKey: .line),
                  name: try c.decode(String.self, forKey: .name),
                  coords: try c.decode([[Double]].self, forKey: .coords))
    }

    static func == (lhs: TransitLine, rhs: TransitLine) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
