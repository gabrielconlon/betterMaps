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
}
