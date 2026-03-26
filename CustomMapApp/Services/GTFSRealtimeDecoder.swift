import Foundation
import SwiftProtobuf
import CoreLocation

// MARK: - GTFS-RT Feed Message (manual protobuf decoding)
// Based on https://gtfs.org/realtime/proto/
// Field numbers match the official gtfs-realtime.proto

/// Decoded vehicle position from GTFS-RT feed
struct GTFSVehiclePosition: Identifiable {
    let id: String
    let routeId: String      // Internal GTFS route_id (e.g., "125593")
    let routeShortName: String // Human-readable (e.g., "39A") — populated from static GTFS lookup
    let tripId: String
    let latitude: Double
    let longitude: Double
    let bearing: Float?
    let speed: Float?
    let timestamp: Date?
    let label: String?
    let vehicleId: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Minimal GTFS-RT protobuf decoder
/// GTFS-RT uses standard protobuf encoding. We decode the key fields manually.
struct GTFSRealtimeDecoder {

    /// Decode a GTFS-RT FeedMessage containing VehiclePositions
    static func decodeVehiclePositions(data: Data) -> [GTFSVehiclePosition] {
        var vehicles: [GTFSVehiclePosition] = []

        // FeedMessage { header=1, entity=2 (repeated) }
        let reader = ProtobufReader(data: data)
        for field in reader.fields {
            if field.number == 2 { // entity
                if let entity = decodeEntity(data: field.data) {
                    vehicles.append(entity)
                }
            }
        }
        return vehicles
    }

    // FeedEntity { id=1, vehicle=4 }
    private static func decodeEntity(data: Data) -> GTFSVehiclePosition? {
        let reader = ProtobufReader(data: data)
        var entityId = ""
        var vehicle: GTFSVehiclePosition?

        for field in reader.fields {
            switch field.number {
            case 1: entityId = field.stringValue ?? ""
            case 4: vehicle = decodeVehiclePosition(data: field.data, entityId: entityId)
            default: break
            }
        }
        return vehicle
    }

    // VehiclePosition { trip=1, vehicle=8, position=2, timestamp=5 }
    private static func decodeVehiclePosition(data: Data, entityId: String) -> GTFSVehiclePosition? {
        let reader = ProtobufReader(data: data)
        var routeId = ""
        var tripId = ""
        var lat = 0.0
        var lng = 0.0
        var bearing: Float?
        var speed: Float?
        var timestamp: Date?
        var label: String?

        for field in reader.fields {
            switch field.number {
            case 1: // TripDescriptor
                let tripReader = ProtobufReader(data: field.data)
                for tf in tripReader.fields {
                    if tf.number == 1 { tripId = tf.stringValue ?? "" }
                    if tf.number == 5 { routeId = tf.stringValue ?? "" }
                }
            case 2: // Position
                let posReader = ProtobufReader(data: field.data)
                for pf in posReader.fields {
                    if pf.number == 1 { lat = Double(pf.floatValue ?? 0) }
                    if pf.number == 2 { lng = Double(pf.floatValue ?? 0) }
                    if pf.number == 3 { bearing = pf.floatValue }
                    if pf.number == 4 { speed = pf.floatValue }
                }
            case 5: // timestamp
                if let ts = field.varintValue {
                    timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
                }
            case 8: // VehicleDescriptor { id=1, label=2 }
                let vReader = ProtobufReader(data: field.data)
                var vid: String?
                for vf in vReader.fields {
                    if vf.number == 1 { vid = vf.stringValue }
                    if vf.number == 2 { label = vf.stringValue }
                }
                // Some feeds put the route in the vehicle label
                if label == nil { label = vid }
            default: break
            }
        }

        guard lat != 0, lng != 0 else { return nil }

        return GTFSVehiclePosition(
            id: entityId,
            routeId: routeId,
            routeShortName: "", // Populated later from static GTFS lookup
            tripId: tripId,
            latitude: lat,
            longitude: lng,
            bearing: bearing,
            speed: speed,
            timestamp: timestamp,
            label: label,
            vehicleId: nil
        )
    }
}

// MARK: - Minimal Protobuf Wire Format Reader

struct ProtobufField {
    let number: Int
    let wireType: Int
    let data: Data
    let rawValue: UInt64?

    var stringValue: String? {
        String(data: data, encoding: .utf8)
    }

    var varintValue: UInt64? {
        rawValue
    }

    var floatValue: Float? {
        guard data.count == 4 else { return nil }
        return data.withUnsafeBytes { $0.load(as: Float.self) }
    }
}

struct ProtobufReader {
    let fields: [ProtobufField]

    init(data: Data) {
        var result: [ProtobufField] = []
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count {
            // Read tag (varint)
            guard let (tag, newOffset) = Self.readVarint(bytes, at: offset) else { break }
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch wireType {
            case 0: // Varint
                guard let (value, next) = Self.readVarint(bytes, at: offset) else { break }
                offset = next
                var varintData = Data()
                withUnsafeBytes(of: value) { varintData.append(contentsOf: $0) }
                result.append(ProtobufField(number: fieldNumber, wireType: wireType, data: varintData, rawValue: value))

            case 1: // 64-bit
                guard offset + 8 <= bytes.count else { break }
                let fieldData = Data(bytes[offset..<offset+8])
                offset += 8
                result.append(ProtobufField(number: fieldNumber, wireType: wireType, data: fieldData, rawValue: nil))

            case 2: // Length-delimited
                guard let (length, next) = Self.readVarint(bytes, at: offset) else { break }
                offset = next
                let len = Int(length)
                guard offset + len <= bytes.count else { break }
                let fieldData = Data(bytes[offset..<offset+len])
                offset += len
                result.append(ProtobufField(number: fieldNumber, wireType: wireType, data: fieldData, rawValue: nil))

            case 5: // 32-bit (float)
                guard offset + 4 <= bytes.count else { break }
                let fieldData = Data(bytes[offset..<offset+4])
                offset += 4
                result.append(ProtobufField(number: fieldNumber, wireType: wireType, data: fieldData, rawValue: nil))

            default:
                break // Unknown wire type, stop
            }
        }
        self.fields = result
    }

    private static func readVarint(_ bytes: [UInt8], at offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var pos = offset
        while pos < bytes.count {
            let byte = bytes[pos]
            result |= UInt64(byte & 0x7F) << shift
            pos += 1
            if byte & 0x80 == 0 {
                return (result, pos)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
