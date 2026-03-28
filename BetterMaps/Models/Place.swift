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
