import XCTest
import CoreLocation
@testable import CustomMapApp

final class DirectionsFormatTests: XCTestCase {
    private func leg(_ mode: TransitMode, minutes: Int, route: String? = nil) -> Leg {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return Leg(id: "\(mode.rawValue)-\(minutes)", mode: mode, routeShortName: route,
                   fromName: "A", toName: "B", start: start,
                   end: start.addingTimeInterval(TimeInterval(minutes * 60)), durationSeconds: minutes * 60)
    }

    func testMinutes() {
        XCTAssertEqual(DirectionsFormat.minutes(42 * 60), "42 min")
        XCTAssertEqual(DirectionsFormat.minutes(65 * 60), "1 h 05 min")
        XCTAssertEqual(DirectionsFormat.minutes(120 * 60), "2 h 00 min")
        XCTAssertEqual(DirectionsFormat.minutes(20), "1 min")
        XCTAssertEqual(DirectionsFormat.minutes(0), "1 min")
        XCTAssertEqual(DirectionsFormat.minutes(59 * 60 + 40), "1 h 00 min")
    }

    func testChipLabels() {
        XCTAssertEqual(DirectionsFormat.chipLabel(leg(.walk, minutes: 3)), "Walk 3")
        XCTAssertEqual(DirectionsFormat.chipLabel(leg(.luas, minutes: 13, route: "Red")), "Luas Red 13")
        XCTAssertEqual(DirectionsFormat.chipLabel(leg(.dart, minutes: 26, route: "DART")), "DART 26")
        XCTAssertEqual(DirectionsFormat.chipLabel(leg(.bus, minutes: 12, route: "39A")), "Bus 39A 12")
        XCTAssertEqual(DirectionsFormat.chipLabel(leg(.rail, minutes: 40, route: "rail")), "Rail 40")
        XCTAssertEqual(DirectionsFormat.chipLabel(leg(.bike, minutes: 18)), "Bike 18")
    }

    func testSummary() {
        XCTAssertEqual(DirectionsFormat.summary(walkSeconds: 9 * 60, bikeSeconds: 0, transfers: 1), "walk 9 min · 1 change")
        XCTAssertEqual(DirectionsFormat.summary(walkSeconds: 9 * 60, bikeSeconds: 0, transfers: 2), "walk 9 min · 2 changes")
        XCTAssertEqual(DirectionsFormat.summary(walkSeconds: 9 * 60, bikeSeconds: 0, transfers: 0), "walk 9 min · no changes")
        XCTAssertEqual(DirectionsFormat.summary(walkSeconds: 0, bikeSeconds: 0, transfers: 0), "No changes")
        XCTAssertEqual(DirectionsFormat.summary(walkSeconds: 0, bikeSeconds: 18 * 60, transfers: 0), "bike 18 min · no changes")
    }

    func testTimeRangeUsesBothEnds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(42 * 60)
        let range = DirectionsFormat.timeRange(start, end)
        XCTAssertEqual(range, "\(DirectionsFormat.clock(start)) – \(DirectionsFormat.clock(end))")
        XCTAssertTrue(range.contains("–"))
    }

    func testDistance() {
        XCTAssertEqual(DirectionsFormat.distance(240), "240 m")
        XCTAssertEqual(DirectionsFormat.distance(243), "240 m")
        XCTAssertEqual(DirectionsFormat.distance(7), "10 m")
        XCTAssertEqual(DirectionsFormat.distance(1200), "1.2 km")
        XCTAssertEqual(DirectionsFormat.distance(2000), "2 km")
        XCTAssertEqual(DirectionsFormat.distance(-5), "0 m")
    }

    func testStopCount() {
        XCTAssertEqual(DirectionsFormat.stopCount(1), "1 stop")
        XCTAssertEqual(DirectionsFormat.stopCount(4), "4 stops")
    }

    func testLegColoursFollowNetwork() {
        XCTAssertEqual(TransitColors.leg(for: leg(.luas, minutes: 1, route: "Red")), TransitColors.luasRedPin)
        XCTAssertEqual(TransitColors.leg(for: leg(.luas, minutes: 1, route: "Green")), TransitColors.luasGrnPin)
        XCTAssertEqual(TransitColors.leg(for: leg(.bus, minutes: 1, route: "39A")), TransitColors.busPin)
        XCTAssertEqual(TransitColors.leg(for: leg(.dart, minutes: 1, route: "DART")), TransitColors.dartPin)
        XCTAssertEqual(TransitColors.leg(for: leg(.rail, minutes: 1)), TransitColors.railPin)
        XCTAssertEqual(TransitColors.leg(for: leg(.walk, minutes: 1)), TransitColors.walkLeg)
        XCTAssertEqual(TransitColors.leg(for: leg(.bike, minutes: 1)), TransitColors.bikeLeg)
    }
}
