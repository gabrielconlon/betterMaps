import XCTest
import SwiftData
@testable import CustomMapApp

/// Stand-in for the entities v2.0 dropped (WeatherRule, SavedRoute,
/// UserProfile): an extra entity that exists in the old store but not in
/// the shipping schema.
@Model
final class LegacyExtra {
    var label: String = ""
    var payload: Data? = nil

    init(label: String) {
        self.label = label
    }
}

/// Proves that opening an on-disk store written with extra entities using
/// the app's current 4-entity schema is a lightweight migration that keeps
/// Place / Layer / Trail data and relationships intact.
@MainActor
final class SchemaUpgradeTests: XCTestCase {
    func testShippingSchemaHasExactlyFourEntities() {
        let names = Set(AppModelContainer.schema.entities.map(\.name))
        XCTAssertEqual(names, ["Place", "Layer", "Trail", "FavoriteTransitRoute"])
    }

    func testDroppingEntitiesKeepsPlacesLayersAndTrails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaUpgradeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("upgrade.store")
        let geometry = TrailGeometry(segments: [
            .init(coordinates: [TestCoords.a, TestCoords.b], snapped: false)
        ])
        let trailPathId = UUID()

        // 1. Write a store with the old (wider) schema.
        try writeOldStore(at: storeURL, geometry: geometry, trailPathId: trailPathId)

        // 2. Reopen with only the shipping schema.
        let config = ModelConfiguration(
            schema: AppModelContainer.schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: [config])
        let context = container.mainContext

        let layers = try context.fetch(FetchDescriptor<Layer>())
        XCTAssertEqual(layers.count, 1)
        let layer = try XCTUnwrap(layers.first)
        XCTAssertEqual(layer.name, "Coffee")
        XCTAssertEqual(layer.colorHex, "#8E5A2B")

        let places = try context.fetch(FetchDescriptor<Place>())
        XCTAssertEqual(places.count, 1)
        let place = try XCTUnwrap(places.first)
        XCTAssertEqual(place.name, "Two Boys Brew")
        XCTAssertEqual(place.latitude, 53.3601, accuracy: 1e-9)
        XCTAssertEqual(place.longitude, -6.2701, accuracy: 1e-9)
        XCTAssertEqual(place.tags, ["coffee", "brunch"])
        XCTAssertEqual(place.layers?.map(\.name), ["Coffee"])

        let trails = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trails.count, 1)
        let trail = try XCTUnwrap(trails.first)
        XCTAssertEqual(trail.name, "Canal loop")
        XCTAssertEqual(trail.pathId, trailPathId)
        XCTAssertEqual(trail.geometry, geometry)
        XCTAssertEqual(trail.layer?.name, "Coffee")

        let favorites = try context.fetch(FetchDescriptor<FavoriteTransitRoute>())
        XCTAssertEqual(favorites.map(\.routeId), ["46A"])
    }

    /// Scoped so the old container is released before the store is reopened.
    private func writeOldStore(at url: URL, geometry: TrailGeometry, trailPathId: UUID) throws {
        let oldSchema = Schema([
            Place.self,
            Layer.self,
            Trail.self,
            FavoriteTransitRoute.self,
            LegacyExtra.self
        ])
        let config = ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: oldSchema, configurations: [config])
        let context = ModelContext(container)

        let layer = Layer(name: "Coffee", colorHex: "#8E5A2B")
        context.insert(layer)

        let place = Place(name: "Two Boys Brew", latitude: 53.3601, longitude: -6.2701, tags: ["coffee", "brunch"])
        context.insert(place)
        place.layers = [layer]

        let trail = Trail(pathId: trailPathId, name: "Canal loop", layer: layer)
        trail.geometry = geometry
        context.insert(trail)

        context.insert(FavoriteTransitRoute(routeId: "46A", shortName: "46A", longName: "Dún Laoghaire - Phoenix Park", routeType: 3))
        context.insert(LegacyExtra(label: "old weather rule"))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LegacyExtra>()), 1)
    }
}
