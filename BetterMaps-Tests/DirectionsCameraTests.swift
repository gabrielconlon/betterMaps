import XCTest
import MapKit
@testable import CustomMapApp

final class DirectionsCameraTests: XCTestCase {
    private let mapSize = CGSize(width: 390, height: 760)
    private let insets = DirectionsCamera.Insets(top: 110, leading: 32, bottom: 404, trailing: 32)
    private let henryStreet = CLLocationCoordinate2D(latitude: 53.3496, longitude: -6.2620)
    private let stephensGreen = CLLocationCoordinate2D(latitude: 53.3382, longitude: -6.2591)

    /// Screen point of `coordinate` when `rect` fills `mapSize`.
    private func screenPoint(_ coordinate: CLLocationCoordinate2D, in rect: MKMapRect) -> CGPoint {
        let point = MKMapPoint(coordinate)
        return CGPoint(x: (point.x - rect.minX) / rect.width * mapSize.width,
                       y: (point.y - rect.minY) / rect.height * mapSize.height)
    }

    func testBothEndsLandInTheUncoveredArea() throws {
        let rect = try XCTUnwrap(DirectionsCamera.rect(fitting: [henryStreet, stephensGreen],
                                                       mapSize: mapSize, insets: insets))
        XCTAssertEqual(rect.width / rect.height, mapSize.width / mapSize.height, accuracy: 1e-9,
                       "the rect keeps the map's aspect so MapKit shows it exactly")
        for end in [henryStreet, stephensGreen] {
            let p = screenPoint(end, in: rect)
            XCTAssertGreaterThanOrEqual(p.x, insets.leading - 0.5)
            XCTAssertLessThanOrEqual(p.x, mapSize.width - insets.trailing + 0.5)
            XCTAssertGreaterThanOrEqual(p.y, insets.top - 0.5)
            XCTAssertLessThanOrEqual(p.y, mapSize.height - insets.bottom + 0.5, "clear of the sheet")
        }
        // North-south journey: the tight axis is vertical, so the ends touch
        // the top and bottom of the uncovered band.
        XCTAssertEqual(screenPoint(henryStreet, in: rect).y, insets.top, accuracy: 0.5)
        XCTAssertEqual(screenPoint(stephensGreen, in: rect).y, mapSize.height - insets.bottom, accuracy: 0.5)
    }

    func testANearbyDestinationKeepsAMinimumSpan() throws {
        let nextDoor = CLLocationCoordinate2D(latitude: 53.3497, longitude: -6.2621)
        let rect = try XCTUnwrap(DirectionsCamera.rect(fitting: [henryStreet, nextDoor],
                                                       mapSize: mapSize, insets: insets))
        let metresAcross = rect.width / MKMapPointsPerMeterAtLatitude(henryStreet.latitude)
        XCTAssertGreaterThanOrEqual(metresAcross, DirectionsCamera.minimumSpanMeters)
    }

    func testNothingToFitOrNoRoomGivesNil() {
        XCTAssertNil(DirectionsCamera.rect(fitting: [], mapSize: mapSize, insets: insets))
        XCTAssertNil(DirectionsCamera.rect(fitting: [henryStreet], mapSize: .zero, insets: insets))
        let crowded = DirectionsCamera.Insets(top: 400, leading: 0, bottom: 400, trailing: 0)
        XCTAssertNil(DirectionsCamera.rect(fitting: [henryStreet], mapSize: mapSize, insets: crowded))
    }
}
