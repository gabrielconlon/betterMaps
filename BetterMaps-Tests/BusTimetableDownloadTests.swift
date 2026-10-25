import XCTest
import os
@testable import CustomMapApp

/// Serves `manifest.json` from memory so download/update paths run without
/// the network. The database download itself is never reached in these
/// tests: every manifest here is rejected (or up to date) before it.
final class StubManifestProtocol: URLProtocol, @unchecked Sendable {
    private struct Config { var body = Data(); var delay: TimeInterval = 0; var requests = 0 }
    private static let config = OSAllocatedUnfairLock(initialState: Config())

    static func reset(body: String, delay: TimeInterval = 0) {
        config.withLock { $0 = Config(body: Data(body.utf8), delay: delay, requests: 0) }
    }

    static var requestCount: Int { config.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, delay) = Self.config.withLock { c -> (Data, TimeInterval) in
            c.requests += 1
            return (c.body, c.delay)
        }
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubManifestProtocol.self]
        return URLSession(configuration: config)
    }
}

final class BusTimetableDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func emptyService() -> BusTimetableService {
        BusTimetableService(databaseURL: dir.appendingPathComponent("transit_timetable.sqlite"),
                            session: StubManifestProtocol.session())
    }

    private func readyService() throws -> BusTimetableService {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini", withExtension: "sqlite"))
        let db = dir.appendingPathComponent("transit_timetable.sqlite")
        try FileManager.default.copyItem(at: source, to: db)
        return BusTimetableService(databaseURL: db, session: StubManifestProtocol.session())
    }

    private func drain(_ stream: AsyncStream<BusTimetableService.DownloadState>) async -> [BusTimetableService.DownloadState] {
        var states: [BusTimetableService.DownloadState] = []
        for await state in stream { states.append(state) }
        return states
    }

    private let failed = BusTimetableService.DownloadState.failed(message: BusTimetableService.unavailableMessage)

    func testManifestWithoutChecksumFailsAndInstallsNothing() async {
        StubManifestProtocol.reset(body: #"{"built":"2026-10-18","schemaVersion":1,"bytes":100}"#)
        let service = emptyService()
        let states = await drain(await service.ensureAvailable())
        XCTAssertEqual(states.last, failed)
        XCTAssertEqual(StubManifestProtocol.requestCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transit_timetable.sqlite").path))
        let info = await service.localInfo()
        XCTAssertNil(info)
    }

    func testMalformedChecksumFails() async {
        StubManifestProtocol.reset(body: #"{"built":"2026-10-18","schemaVersion":1,"sha256":"abc"}"#)
        let states = await drain(await emptyService().ensureAvailable())
        XCTAssertEqual(states.last, failed)
    }

    /// Remove mid-download, then Download again: the second request must
    /// start a fresh download, and the cancelled one must not overwrite it.
    func testRedownloadRightAfterRemoveStartsFreshAndIgnoresCancelledTask() async throws {
        StubManifestProtocol.reset(body: #"{"built":"2026-10-18","schemaVersion":1}"#, delay: 0.4)
        let service = emptyService()
        _ = await service.ensureAvailable()
        await service.deleteDownload()
        let afterRemove = await service.currentState()
        XCTAssertEqual(afterRemove, .notDownloaded)

        let states = await drain(await service.ensureAvailable())
        XCTAssertEqual(states.first, .downloading(fraction: 0))
        XCTAssertEqual(states.last, failed, "the second download ran to its own end")
        XCTAssertEqual(StubManifestProtocol.requestCount, 2)

        // Let any straggler from the first task finish; it must not clobber.
        try await Task.sleep(for: .milliseconds(600))
        let final = await service.currentState()
        XCTAssertEqual(final, failed)
    }

    func testCheckForUpdateReportsUpToDate() async throws {
        let sha = String(repeating: "a", count: 64)
        StubManifestProtocol.reset(body: #"{"built":"2026-10-18","schemaVersion":1,"sha256":"\#(sha)"}"#)
        let service = try readyService()
        let result = await service.checkForUpdate()
        XCTAssertEqual(result, .upToDate)
        let state = await service.currentState()
        XCTAssertEqual(state, .ready(builtDate: "2026-10-18"))
    }

    func testCheckForUpdateWithUnverifiableNewerBuildFailsAndKeepsCurrent() async throws {
        StubManifestProtocol.reset(body: #"{"built":"2026-11-01","schemaVersion":1}"#)
        let service = try readyService()
        let result = await service.checkForUpdate()
        XCTAssertEqual(result, .failed)
        let state = await service.currentState()
        XCTAssertEqual(state, .ready(builtDate: "2026-10-18"))
    }

    func testCheckForUpdateWithoutTimetableFails() async {
        StubManifestProtocol.reset(body: "{}")
        let result = await emptyService().checkForUpdate()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(StubManifestProtocol.requestCount, 0)
    }

    @MainActor
    func testModelExposesUpdateResult() async throws {
        let sha = String(repeating: "b", count: 64)
        StubManifestProtocol.reset(body: #"{"built":"2026-10-18","schemaVersion":1,"sha256":"\#(sha)"}"#)
        let model = BusTimetableModel(service: try readyService())
        XCTAssertNil(model.updateResultText)
        let result = await model.checkForUpdateNow()
        XCTAssertEqual(result, .upToDate)
        XCTAssertFalse(model.isCheckingForUpdate)
        XCTAssertEqual(model.updateResultText, "Up to date")
        XCTAssertEqual(BusTimetableModel.text(for: .updated), "Updated")
    }

    // MARK: - Install location

    /// Builds before the move kept the timetable in Caches; the first launch
    /// after the update must move it, not ask for the download again.
    func testLegacyInstallIsMovedAndServesQueries() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "timetable_mini", withExtension: "sqlite"))
        let legacy = dir.appendingPathComponent("Caches/transit_timetable.sqlite")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: legacy)
        try Data(#"{"built":"2026-10-18"}"#.utf8).write(to: BusTimetableService.manifestURL(for: legacy))
        let destination = dir.appendingPathComponent("Support/Transit/transit_timetable.sqlite")

        let service = BusTimetableService(databaseURL: destination, legacyDatabaseURL: legacy,
                                          session: StubManifestProtocol.session())
        let state = await service.currentState()

        XCTAssertEqual(state, .ready(builtDate: "2026-10-18"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: BusTimetableService.manifestURL(for: destination).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyInstallNeverOverwritesCurrentOne() throws {
        let legacy = dir.appendingPathComponent("old.sqlite")
        let current = dir.appendingPathComponent("new.sqlite")
        try Data("old".utf8).write(to: legacy)
        try Data("new".utf8).write(to: current)

        XCTAssertFalse(BusTimetableService.moveLegacyInstall(from: legacy, to: current))
        XCTAssertEqual(try Data(contentsOf: current), Data("new".utf8))
        XCTAssertFalse(BusTimetableService.moveLegacyInstall(from: dir.appendingPathComponent("missing.sqlite"),
                                                             to: dir.appendingPathComponent("other.sqlite")))
    }

    // MARK: - Service window

    func testCoverageAgainstValidTo() {
        XCTAssertTrue(BusTimetableService.covers(day: "20261216", validTo: "20261216"))
        XCTAssertFalse(BusTimetableService.covers(day: "20261217", validTo: "20261216"))
        XCTAssertTrue(BusTimetableService.covers(day: "20270101", validTo: nil), "no window recorded: don't claim it's stale")
    }

    func testFixtureCoversItsWindowOnly() async throws {
        let service = try readyService()
        let inside = try XCTUnwrap(BusTimetableService.isoDay("2026-10-20")).addingTimeInterval(12 * 3600)
        let after = try XCTUnwrap(BusTimetableService.isoDay("2026-12-20")).addingTimeInterval(12 * 3600)
        let coversInside = await service.covers(inside)
        let coversAfter = await service.covers(after)
        XCTAssertTrue(coversInside)
        XCTAssertFalse(coversAfter)
    }

    // MARK: - Staleness

    func testTimetableOlderThanTheAppsStopsIsStale() throws {
        let now = try XCTUnwrap(BusTimetableService.isoDay("2026-10-26"))
        let bundle = BusTimetableService.isoDay("2026-10-25")
        XCTAssertTrue(BusTimetableService.isStale(built: "2026-10-19", days: 14, bundleBuilt: bundle, now: now),
                      "an app update with more stops pulls the matching timetable without waiting 14 days")
        XCTAssertFalse(BusTimetableService.isStale(built: "2026-10-25", days: 14, bundleBuilt: bundle, now: now))
        XCTAssertFalse(BusTimetableService.isStale(built: "2026-10-19", days: 14, bundleBuilt: nil, now: now))
        XCTAssertTrue(BusTimetableService.isStale(built: "2026-10-01", days: 14, bundleBuilt: nil, now: now))
        XCTAssertTrue(BusTimetableService.isStale(built: nil, days: 14, bundleBuilt: nil, now: now))
    }
}
