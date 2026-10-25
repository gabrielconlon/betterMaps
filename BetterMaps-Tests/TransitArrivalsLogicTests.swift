import XCTest
import CoreLocation
import SQLite3
@testable import CustomMapApp

/// Pure helpers behind the arrivals sheet, plus the autumn DST change.
final class TransitArrivalsLogicTests: XCTestCase {

    // MARK: - Departed buses

    private func departure(at date: Date, route: String = "39A") -> BusDeparture {
        BusDeparture(routeId: route, routeShortName: route, headsign: "UCD", direction: 0,
                     serviceDate: "20261018", departureSeconds: 0, departure: date)
    }

    func testUpcomingDropsDeparturesOlderThanThirtySeconds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deps = [-120.0, -31, -30, -5, 0, 45, 600].map { departure(at: now.addingTimeInterval($0)) }
        let kept = BusDeparture.upcoming(deps, now: now)
        XCTAssertEqual(kept.map { $0.departure.timeIntervalSince(now) }, [-30, -5, 0, 45, 600])
        XCTAssertEqual(kept.first?.minutesUntil(now), 0, "just-left bus within grace still reads Due")
    }

    func testUpcomingCustomGraceAndEmpty() {
        let now = Date()
        XCTAssertTrue(BusDeparture.upcoming([], now: now).isEmpty)
        let deps = [departure(at: now.addingTimeInterval(-10))]
        XCTAssertTrue(BusDeparture.upcoming(deps, now: now, grace: 5).isEmpty)
    }

    // MARK: - Route labels

    func testRailRoutesReadAsRail() {
        XCTAssertEqual(TransitArrivalsView.routeLabel("rail"), "Rail")
        XCTAssertEqual(TransitArrivalsView.routeLabel("DART"), "DART")
        XCTAssertEqual(TransitArrivalsView.routeLabel("39A"), "39A")
        XCTAssertEqual(TransitArrivalsView.routeLabel("Red"), "Red")
    }

    // MARK: - Nearest Irish Rail station

    private func station(_ code: String, _ lat: Double, _ lon: Double) -> IrishRailStation {
        IrishRailStation(id: code, name: code, latitude: lat, longitude: lon, type: .dart)
    }

    func testNearestStationPicksClosestNotFirst() {
        // Tara Street stop; Pearse is ~600 m away and listed first.
        let tara = CLLocationCoordinate2D(latitude: 53.3471, longitude: -6.2545)
        let stations = [
            station("PERSE", 53.3433, -6.2491),
            station("TARA", 53.3470, -6.2543),
            station("CNLLY", 53.3531, -6.2490),
        ]
        XCTAssertEqual(IrishRailStation.nearest(to: tara, in: stations)?.id, "TARA")
        XCTAssertEqual(IrishRailStation.nearest(to: tara, in: Array(stations.reversed()))?.id, "TARA")
    }

    func testNearestStationRespectsRadius() {
        let here = CLLocationCoordinate2D(latitude: 53.3471, longitude: -6.2545)
        let far = [station("BRAY", 53.2043, -6.1007)]
        XCTAssertNil(IrishRailStation.nearest(to: here, in: far))
        XCTAssertNil(IrishRailStation.nearest(to: here, in: []))
    }

    // MARK: - Status colour

    func testDisruptionKeywords() {
        XCTAssertTrue(TransitFeed.isDisruption("Cancelled"))
        XCTAssertTrue(TransitFeed.isDisruption("Delayed by 10 mins"))
        XCTAssertTrue(TransitFeed.isDisruption("Green Line services suspended between X and Y"))
        XCTAssertFalse(TransitFeed.isDisruption("En Route"))
        XCTAssertFalse(TransitFeed.isDisruption("Green Line services operating normally"))
        XCTAssertFalse(TransitFeed.isDisruption(""))
    }

    // MARK: - Pinned stops

    func testPinnedStopsResolveInOrderSkippingUnknownAndDuplicates() {
        let a = TransitStop(id: "A", name: "Abbey", latitude: 53, longitude: -6, kind: .luas,
                            line: "red", altIds: ["A2"])
        let b = TransitStop(id: "B", name: "Bray", latitude: 53, longitude: -6, kind: .dart)
        let lookup: (String) -> TransitStop? = { id in [a, b].first { $0.id == id || $0.altIds.contains(id) } }
        let resolved = PinnedStopsGroup.resolve(["B", "zzz", "A2", "A"], using: lookup)
        XCTAssertEqual(resolved.map(\.id), ["B", "A"])
        XCTAssertTrue(PinnedStopsGroup.resolve([], using: lookup).isEmpty)
    }

    // MARK: - Timetable date label

    func testTimetableUpdatedLabelIsFormattedNotISO() throws {
        let label = try XCTUnwrap(TransitArrivalsView.timetableUpdatedLabel("2026-10-18"))
        XCTAssertTrue(label.hasPrefix("Timetable updated "))
        XCTAssertFalse(label.contains("2026-10-18"))
        XCTAssertTrue(label.contains("18"))
        XCTAssertNil(TransitArrivalsView.timetableUpdatedLabel("garbage"))
    }

    // MARK: - DST: Sunday 25 Oct 2026, clocks go back 02:00 IST → 01:00 GMT

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testServiceDaySecondsFollowNoonMinusTwelveOnAutumnChange() {
        // Service day 25 Oct starts at noon GMT − 12 h = 00:00Z (01:00 IST).
        XCTAssertEqual(BusTimetableService.serviceDayStart("20261025"), utc(2026, 10, 25, 0, 0))
        // 01:30 IST (first 01:30) = 00:30Z → 1800 s, not the 5400 wall-clock seconds.
        let first = BusTimetableService.serviceDay(containing: utc(2026, 10, 25, 0, 30))
        XCTAssertEqual(first.day, "20261025")
        XCTAssertEqual(first.seconds, 1800)
        // 01:30 GMT (second 01:30) = 01:30Z → 5400 s.
        XCTAssertEqual(BusTimetableService.serviceDay(containing: utc(2026, 10, 25, 1, 30)).seconds, 5400)
        // Ordinary day unchanged.
        XCTAssertEqual(BusTimetableService.serviceDay(containing: utc(2026, 10, 20, 23, 30)).seconds, 1800)
    }

    func testDepartureJustAfterAutumnChangeIsFound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini", withExtension: "sqlite"))
        let dbURL = dir.appendingPathComponent("transit_timetable.sqlite")
        try FileManager.default.copyItem(at: source, to: dbURL)

        // A DAILY 39A trip from 8220DB000003 at GTFS 00:40 → 00:40Z on 25 Oct
        // (01:40 IST, before the clocks go back at 01:00Z).
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        let sql = """
            INSERT INTO trips(id, route, service, dir, headsign)
              SELECT 9999, r.id, s.id, 0, 'DST' FROM routes r, services s
              WHERE r.gtfs_id = 'MINI-39A' AND s.gtfs_id = 'DAILY';
            INSERT INTO stop_times(stop, dep, trip)
              SELECT id, 2400, 9999 FROM stops WHERE gtfs_id = '8220DB000003';
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let service = BusTimetableService(databaseURL: dbURL)
        let now = utc(2026, 10, 25, 0, 30)  // 01:30 IST
        let deps = try await service.departures(stopId: "8220DB000003", from: now)
        let dep = try XCTUnwrap(deps.first { $0.headsign == "DST" })
        XCTAssertEqual(dep.serviceDate, "20261025")
        XCTAssertEqual(dep.departure, utc(2026, 10, 25, 0, 40))
        XCTAssertEqual(dep.minutesUntil(now), 10)
        XCTAssertEqual(dep.scheduledTime, "01:40")
    }
}
