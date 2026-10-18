import XCTest
import CoreLocation
@testable import CustomMapApp

final class PlaceLookupServiceTests: XCTestCase {

    private struct FakeProvider: PlaceLookupProvider {
        var poi: String?
        var address: String?
        var delay: Duration = .zero

        func pointOfInterestName(near coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) async -> String? {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return poi
        }

        func address(for coordinate: CLLocationCoordinate2D) async -> String? {
            address
        }
    }

    /// Ignores cancellation entirely, like a geocoder that never returns.
    private struct StuckProvider: PlaceLookupProvider {
        func pointOfInterestName(near coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) async -> String? {
            let start = ContinuousClock.now
            while ContinuousClock.now - start < .seconds(2) {
                await Task.yield()
            }
            return "Too late"
        }

        func address(for coordinate: CLLocationCoordinate2D) async -> String? { "Too late" }
    }

    private let pearseSt = CLLocationCoordinate2D(latitude: 53.3438, longitude: -6.2546)

    func testPOIFoundReturnsItsName() async {
        let service = PlaceLookupService(provider: FakeProvider(poi: "Kennedy's Pub", address: "12 Pearse St"))
        let name = await service.lookup(pearseSt)
        XCTAssertEqual(name, "Kennedy's Pub")
    }

    func testMissingPOIFallsBackToAddress() async {
        let service = PlaceLookupService(provider: FakeProvider(poi: nil, address: "12 Pearse St"))
        let name = await service.lookup(pearseSt)
        XCTAssertEqual(name, "12 Pearse St")
    }

    func testEmptyPOINameFallsBackToAddress() async {
        let service = PlaceLookupService(provider: FakeProvider(poi: "", address: "12 Pearse St"))
        let name = await service.lookup(pearseSt)
        XCTAssertEqual(name, "12 Pearse St")
    }

    func testBothFailReturnsNil() async {
        let service = PlaceLookupService(provider: FakeProvider(poi: nil, address: nil))
        let name = await service.lookup(pearseSt)
        XCTAssertNil(name)
    }

    func testTimeoutReturnsNil() async {
        let service = PlaceLookupService(provider: FakeProvider(poi: "Late", delay: .seconds(5)),
                                         timeout: .milliseconds(100))
        let start = ContinuousClock.now
        let name = await service.lookup(pearseSt)
        XCTAssertNil(name)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testTimeoutReturnsEvenWhenProviderIgnoresCancellation() async {
        let service = PlaceLookupService(provider: StuckProvider(), timeout: .milliseconds(100))
        let start = ContinuousClock.now
        let name = await service.lookup(pearseSt)
        XCTAssertNil(name)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testCancellingTheCallerReturnsNil() async {
        let service = PlaceLookupService(provider: FakeProvider(poi: "Late", delay: .seconds(5)))
        let coordinate = pearseSt
        let task = Task { await service.lookup(coordinate) }
        task.cancel()
        let name = await task.value
        XCTAssertNil(name)
    }

    func testAddressFormatting() {
        XCTAssertEqual(PlaceLookupService.formatAddress(subThoroughfare: "12", thoroughfare: "Pearse Street",
                                                        name: "12 Pearse Street", locality: "Dublin"),
                       "12 Pearse St")
        XCTAssertEqual(PlaceLookupService.formatAddress(subThoroughfare: nil, thoroughfare: "Grand Canal Road",
                                                        name: nil, locality: "Dublin"),
                       "Grand Canal Rd")
        XCTAssertEqual(PlaceLookupService.formatAddress(subThoroughfare: nil, thoroughfare: nil,
                                                        name: "Phoenix Park", locality: "Dublin"),
                       "Phoenix Park")
        XCTAssertEqual(PlaceLookupService.formatAddress(subThoroughfare: nil, thoroughfare: " ",
                                                        name: nil, locality: "Dublin"),
                       "Dublin")
        XCTAssertNil(PlaceLookupService.formatAddress(subThoroughfare: nil, thoroughfare: nil,
                                                      name: nil, locality: nil))
    }
}
