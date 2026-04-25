import Foundation
import SwiftData
import CoreLocation

@Model
final class Place {
    var id: UUID = UUID()
    var name: String = ""
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var notes: String = ""
    var rating: Int = 0
    var hoursInfo: String = ""
    var tags: [String] = []
    /// For places used in a waypoint-path layer: when true this point is a path endpoint
    /// and is connected to only its single nearest neighbor instead of two.
    var isWaypointEndpoint: Bool = false
    /// Groups waypoints into independent paths within the same waypoint-path layer.
    /// Two waypoints with the same pathId are part of the same connected line; with
    /// different pathIds they belong to separate lines (e.g., Grand Canal Trail vs
    /// Phoenix Park Loop, both in the user's "Walking Trails" layer). Optional so
    /// existing waypoints written before this field existed default to nil — the
    /// renderer treats nil as a single legacy bucket so old data keeps working.
    var pathId: UUID? = nil

    @Attribute(.externalStorage)
    var photoData: [Data] = []

    @Relationship(inverse: \Layer.places)
    var layers: [Layer]? = []

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        name: String = "",
        latitude: Double = 0.0,
        longitude: Double = 0.0,
        notes: String = "",
        rating: Int = 0,
        hoursInfo: String = "",
        tags: [String] = []
    ) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.notes = notes
        self.rating = rating
        self.hoursInfo = hoursInfo
        self.tags = tags
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
