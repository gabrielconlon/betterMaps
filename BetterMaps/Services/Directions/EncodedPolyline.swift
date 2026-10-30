import Foundation
import CoreLocation

/// Google's encoded polyline algorithm, generalised to any decimal precision
/// (MOTIS emits 6 or 7 places; Google's reference uses 5).
enum EncodedPolyline {
    /// Decodes `s`; a truncated or corrupt tail yields whatever was decoded
    /// before it, never a crash.
    static func decode(_ s: String, precision: Int) -> [CLLocationCoordinate2D] {
        let factor = Self.factor(precision)
        var coordinates: [CLLocationCoordinate2D] = []
        var lat: Int64 = 0
        var lon: Int64 = 0
        var index = s.utf8.startIndex
        let end = s.utf8.endIndex

        func next() -> Int64? {
            var result: Int64 = 0
            var shift: Int64 = 0
            while index < end {
                let byte = Int64(s.utf8[index]) - 63
                s.utf8.formIndex(after: &index)
                guard byte >= 0, shift < 64 else { return nil }
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < end {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            coordinates.append(CLLocationCoordinate2D(latitude: Double(lat) / factor,
                                                      longitude: Double(lon) / factor))
        }
        return coordinates
    }

    static func encode(_ coords: [CLLocationCoordinate2D], precision: Int) -> String {
        let factor = Self.factor(precision)
        var output = ""
        var lastLat: Int64 = 0
        var lastLon: Int64 = 0
        for c in coords {
            let lat = Int64((c.latitude * factor).rounded())
            let lon = Int64((c.longitude * factor).rounded())
            append(lat - lastLat, to: &output)
            append(lon - lastLon, to: &output)
            lastLat = lat
            lastLon = lon
        }
        return output
    }

    private static func factor(_ precision: Int) -> Double {
        pow(10, Double(max(precision, 0)))
    }

    private static func append(_ value: Int64, to output: inout String) {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        while v >= 0x20 {
            output.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63)))
            v >>= 5
        }
        output.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
    }
}
