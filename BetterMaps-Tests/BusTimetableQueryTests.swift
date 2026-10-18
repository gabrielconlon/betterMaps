import XCTest
@testable import CustomMapApp

/// Queries against the committed `Fixtures/gtfs_mini/timetable_mini.sqlite`
/// (built with `--today 2026-10-18`); expected numbers from scripts/README.md.
final class BusTimetableQueryTests: XCTestCase {
    private var dir: URL!
    private var service: BusTimetableService!

    override func setUp() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini", withExtension: "sqlite"))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("transit_timetable.sqlite")
        try FileManager.default.copyItem(at: source, to: db)
        service = BusTimetableService(databaseURL: db)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func dublin(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        BusTimetableService.dublin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private let twoDays: TimeInterval = 2 * 86400

    func testStateIsReadyWithBuiltDate() async {
        let state = await service.currentState()
        XCTAssertEqual(state, .ready(builtDate: "2026-10-18"))
        let info = await service.localInfo()
        XCTAssertEqual(info?.built, "2026-10-18")
        XCTAssertGreaterThan(info?.bytes ?? 0, 0)
    }

    func testTuesdayDeparturesAfterEight() async throws {
        let deps = try await service.departures(stopId: "8220DB000002", from: dublin(2026, 10, 20, 8), window: twoDays)
        XCTAssertEqual(deps.map(\.departureSeconds), [29100, 90600])
        XCTAssertTrue(deps.allSatisfy { $0.routeShortName == "39A" && $0.headsign == "UCD" && $0.routeId == "MINI-39A" })
        XCTAssertTrue(deps.allSatisfy { $0.serviceDate == "20261020" })
        XCTAssertEqual(deps.first?.departure, dublin(2026, 10, 20, 8, 5))
        XCTAssertEqual(deps.first?.scheduledTime, "08:05")
        XCTAssertEqual(deps.last?.departure, dublin(2026, 10, 21, 1, 10))
    }

    func testExceptionDayHasNoDepartures() async throws {
        let deps = try await service.departures(stopId: "8220DB000002", from: dublin(2026, 10, 26, 0), window: twoDays)
        XCTAssertTrue(deps.isEmpty)
    }

    func testSaturdayOnlyMergedService() async throws {
        let deps = try await service.departures(stopId: "8220DB000002", from: dublin(2026, 10, 24, 8), window: twoDays)
        XCTAssertEqual(deps.map(\.departureSeconds), [29100])
    }

    func testAfterMidnightTripComesFromPreviousServiceDay() async throws {
        let deps = try await service.departures(stopId: "8220DB000002", from: dublin(2026, 10, 21, 0, 30))
        let late = try XCTUnwrap(deps.first)
        XCTAssertEqual(late.departureSeconds, 90600)
        XCTAssertEqual(late.serviceDate, "20261020")
        XCTAssertEqual(late.routeShortName, "39A")
        XCTAssertEqual(late.departure, dublin(2026, 10, 21, 1, 10))
        XCTAssertEqual(late.scheduledTime, "01:10")
        XCTAssertEqual(late.minutesUntil(dublin(2026, 10, 21, 0, 30)), 40)
    }

    func testDefaultWindowIsTwoHours() async throws {
        let deps = try await service.departures(stopId: "8220DB000002", from: dublin(2026, 10, 20, 8))
        XCTAssertEqual(deps.map(\.departureSeconds), [29100])
    }

    func testAltIdsAreUnioned() async throws {
        let at = dublin(2026, 10, 20, 8)
        let mainOnly = try await service.departures(stopId: "8220GA00408", from: at, window: twoDays)
        XCTAssertTrue(mainOnly.isEmpty)
        let merged = try await service.departures(stopId: "8220GA00408", altIds: ["8220GA00409"], from: at, window: twoDays)
        XCTAssertEqual(merged.map(\.departureSeconds), [33000])
        XCTAssertEqual(merged.first?.headsign, "Tallaght")
    }

    func testTaraStreetDart() async throws {
        let deps = try await service.departures(stopId: "8220IR0025", from: dublin(2026, 10, 20, 7), window: twoDays)
        XCTAssertEqual(deps.map(\.departureSeconds), [28500])
        XCTAssertEqual(deps.first?.routeShortName, "DART")
        XCTAssertEqual(deps.first?.headsign, "Greystones")
    }

    func testLimit() async throws {
        let deps = try await service.departures(stopId: "8220DB000002", from: dublin(2026, 10, 20, 8),
                                                window: twoDays, limit: 1)
        XCTAssertEqual(deps.count, 1)
    }

    func testRoutesForTerminusStop() async throws {
        let routes = try await service.routes(forStop: "8220DB000004")
        XCTAssertEqual(routes.map(\.short), ["39A"])
        XCTAssertEqual(routes.first?.kind, .bus)
        let none = try await service.departures(stopId: "8220DB000004", from: dublin(2026, 10, 20, 0), window: twoDays)
        XCTAssertTrue(none.isEmpty, "drop-off-only terminus has no departures")
    }

    func testRouteShape() async throws {
        let shape = try await service.routeShape(routeId: "MINI-39A", dir: 0)
        XCTAssertEqual(shape?.count, 4)
        let missing = try await service.routeShape(routeId: "MINI-39A", dir: 1)
        XCTAssertNil(missing)
    }

    func testMissingDatabaseIsNotDownloaded() async {
        let empty = BusTimetableService(databaseURL: dir.appendingPathComponent("nope.sqlite"))
        let state = await empty.currentState()
        XCTAssertEqual(state, .notDownloaded)
        do {
            _ = try await empty.departures(stopId: "8220DB000002", from: Date())
            XCTFail("expected notAvailable")
        } catch {}
    }

    func testDeleteDownload() async {
        await service.deleteDownload()
        let state = await service.currentState()
        XCTAssertEqual(state, .notDownloaded)
        let info = await service.localInfo()
        XCTAssertNil(info)
    }

    func testGunzipAndChecksum() throws {
        let gz = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini.sqlite", withExtension: "gz"))
        let raw = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini", withExtension: "sqlite"))
        let out = dir.appendingPathComponent("out.sqlite")
        try BusTimetableService.gunzip(gz, to: out)
        XCTAssertEqual(try BusTimetableService.sha256Hex(of: out), try BusTimetableService.sha256Hex(of: raw))
        XCTAssertEqual(try BusTimetableService.sha256Hex(of: raw).count, 64)

        // Corrupt input is rejected, not written as a half file that passes.
        let bad = dir.appendingPathComponent("bad.gz")
        try Data((try Data(contentsOf: gz)).prefix(200)).write(to: bad)
        XCTAssertThrowsError(try BusTimetableService.gunzip(bad, to: dir.appendingPathComponent("bad.sqlite")))
    }

    func testServiceDayHelpers() {
        XCTAssertEqual(BusTimetableService.addingDays(-1, to: "20261101"), "20261031")
        XCTAssertEqual(BusTimetableService.serviceDay(containing: dublin(2026, 10, 21, 0, 30)).day, "20261021")
        XCTAssertEqual(BusTimetableService.serviceDay(containing: dublin(2026, 10, 21, 0, 30)).seconds, 1800)
    }
}
