import Foundation
import SwiftData
import CoreLocation

/// Persistently saved route for offline use.
/// Stored via SwiftData — survives app restarts, works without internet.
@Model
final class SavedRoute {
    var id: UUID = UUID()
    var name: String = ""

    // Endpoints
    var originName: String = ""
    var originLatitude: Double = 0
    var originLongitude: Double = 0
    var destinationName: String = ""
    var destinationLatitude: Double = 0
    var destinationLongitude: Double = 0

    // Route data
    var mode: String = "driving"  // TransportMode rawValue
    var etaSeconds: Double = 0
    var distanceMeters: Double = 0

    // Polyline coordinates stored as JSON array of [lat, lng] pairs
    // This is the key data that lets us draw the route offline
    @Attribute(.externalStorage)
    var polylineJSON: Data = Data()

    // Metadata
    var bikeLaneInfo: String?
    var savedAt: Date = Date()
    var lastUsed: Date = Date()
    var notes: String = ""

    var transportMode: TransportMode {
        TransportMode(rawValue: mode) ?? .driving
    }

    var originCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: originLatitude, longitude: originLongitude)
    }

    var destinationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
    }

    /// Decode stored polyline coordinates
    var coordinates: [CLLocationCoordinate2D] {
        guard let pairs = try? JSONDecoder().decode([[Double]].self, from: polylineJSON) else { return [] }
        return pairs.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }

    init(
        name: String = "",
        originName: String = "",
        origin: CLLocationCoordinate2D = CLLocationCoordinate2D(),
        destinationName: String = "",
        destination: CLLocationCoordinate2D = CLLocationCoordinate2D(),
        mode: TransportMode = .driving,
        etaSeconds: Double = 0,
        distanceMeters: Double = 0,
        coordinates: [CLLocationCoordinate2D] = [],
        bikeLaneInfo: String? = nil,
        notes: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.originName = originName
        self.originLatitude = origin.latitude
        self.originLongitude = origin.longitude
        self.destinationName = destinationName
        self.destinationLatitude = destination.latitude
        self.destinationLongitude = destination.longitude
        self.mode = mode.rawValue
        self.etaSeconds = etaSeconds
        self.distanceMeters = distanceMeters
        self.bikeLaneInfo = bikeLaneInfo
        self.notes = notes
        self.savedAt = Date()
        self.lastUsed = Date()

        // Encode coordinates to JSON
        let pairs = coordinates.map { [$0.latitude, $0.longitude] }
        self.polylineJSON = (try? JSONEncoder().encode(pairs)) ?? Data()
    }
}
