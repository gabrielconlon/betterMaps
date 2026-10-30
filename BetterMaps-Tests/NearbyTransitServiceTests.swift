import XCTest
import CoreLocation
@testable import CustomMapApp

/// Nearby stops around Abbey Street, with routes from the committed
/// `gtfs_mini` timetable (same fixture as `BusTimetableQueryTests`).
final class NearbyTransitServiceTests: XCTestCase {
    private var dir: URL!

    private let abbeyStreet = CLLocationCoordinate2D(latitude: 53.3485, longitude: -6.2585)

    /// The fixture's stops as the bundle would describe them.
    private var grid: TransitSpatialGrid {
        TransitSpatialGrid(stops: [
            TransitStop(id: "8220GA00408", name: "Abbey Street", latitude: 53.3485, longitude: -6.2585,
                        kind: .luas, line: "red", altIds: ["8220GA00409"]),
            makeStop(id: "8220DB000004", name: "Eden Quay", lat: 53.3479, lon: -6.2562),
            makeStop(id: "8220IR0025", name: "Tara Street", lat: 53.347264, lon: -6.254359, type: .dart),
            TransitStop(id: "8220GA00404", name: "Jervis", latitude: 53.34768, longitude: -6.26528,
                        kind: .luas, line: "red"),
            makeStop(id: "8220DB000002", name: "Parnell Square", lat: 53.3532, lon: -6.2634),
        ])
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func installedService() throws -> BusTimetableService {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini", withExtension: "sqlite"))
        let db = dir.appendingPathComponent("transit_timetable.sqlite")
        try FileManager.default.copyItem(at: source, to: db)
        return BusTimetableService(databaseURL: db)
    }

    func testNearestFirstWithRoutesWithinRadius() async throws {
        let service = NearbyTransitService(timetable: try installedService())
        let found = await service.nearby(abbeyStreet, grid: grid, radiusMeters: 350)

        XCTAssertEqual(found.map(\.stop.id), ["8220GA00408", "8220DB000004", "8220IR0025"])
        XCTAssertTrue(found.allSatisfy(\.routesKnown))
        XCTAssertEqual(found[0].routes.map(\.short), ["Red"])
        XCTAssertEqual(found[1].routes.map(\.short), ["39A"])
        XCTAssertEqual(found[2].routes.map(\.short), ["DART"])

        XCTAssertEqual(found[0].distanceMeters, 0, accuracy: 1)
        XCTAssertEqual(found[1].distanceMeters, 167, accuracy: 15)
        XCTAssertEqual(found[2].distanceMeters, 307, accuracy: 15)
        XCTAssertTrue(found.map(\.distanceMeters) == found.map(\.distanceMeters).sorted())
    }

    func testLimitAndWiderRadius() async throws {
        let service = NearbyTransitService(timetable: try installedService())
        let wide = await service.nearby(abbeyStreet, grid: grid, radiusMeters: 700, limit: 8)
        XCTAssertEqual(wide.map(\.stop.id), ["8220GA00408", "8220DB000004", "8220IR0025", "8220GA00404", "8220DB000002"])
        let two = await service.nearby(abbeyStreet, grid: grid, radiusMeters: 700, limit: 2)
        XCTAssertEqual(two.map(\.stop.id), ["8220GA00408", "8220DB000004"])
    }

    func testNothingNearbyIsEmpty() async throws {
        let service = NearbyTransitService(timetable: try installedService())
        let found = await service.nearby(Dublin.howth, grid: grid, radiusMeters: 400)
        XCTAssertTrue(found.isEmpty)
    }

    func testMissingTimetableLeavesRoutesUnknownAndDoesNotDownload() async {
        let missing = BusTimetableService(databaseURL: dir.appendingPathComponent("absent.sqlite"))
        let service = NearbyTransitService(timetable: missing)
        let found = await service.nearby(abbeyStreet, grid: grid, radiusMeters: 350)

        XCTAssertEqual(found.map(\.stop.id), ["8220GA00408", "8220DB000004", "8220IR0025"])
        XCTAssertTrue(found.allSatisfy { !$0.routesKnown && $0.routes.isEmpty })
        let state = await missing.currentState()
        XCTAssertEqual(state, .notDownloaded, "a place card must never start the timetable download")
    }
}
