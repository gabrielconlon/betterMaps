import XCTest
import CoreLocation
@testable import CustomMapApp

/// A bundle that reports a fixed marketing version (or none).
private final class StubBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var version: String? = "1.2.3"
    override func object(forInfoDictionaryKey key: String) -> Any? {
        key == "CFBundleShortVersionString" ? Self.version : nil
    }
}

final class MotisQueryTests: XCTestCase {
    private let heuston = CLLocationCoordinate2D(latitude: 53.3465, longitude: -6.2943)
    private let dunLaoghaire = CLLocationCoordinate2D(latitude: 53.2946, longitude: -6.1340)
    /// 2026-11-03T08:36:00Z
    private let departure = Date(timeIntervalSince1970: 1_793_694_960)

    private func prefs(modes: Set<TransitMode> = [.bus, .luas, .dart, .rail], bike: Bool = true,
                       walk: Int = 10, transfers: Int = 2) -> DirectionsPreferencesSnapshot {
        DirectionsPreferencesSnapshot(
            walkToleranceMinutes: walk, enabledModes: modes, allowBikeDirect: bike,
            maxTransfers: transfers, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50)
    }

    private func request(_ preferences: DirectionsPreferencesSnapshot, arriveBy: Bool = false) -> JourneyRequest {
        JourneyRequest(origin: heuston, destination: dunLaoghaire, time: departure,
                       arriveBy: arriveBy, preferences: preferences)
    }

    /// Query items by name; fails the test on a duplicate name.
    private func items(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String?] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false), file: file, line: line)
        var result: [String: String?] = [:]
        for item in components.queryItems ?? [] {
            XCTAssertNil(result[item.name], "duplicate query item \(item.name)", file: file, line: line)
            result[item.name] = item.value
        }
        return result
    }

    func testDefaultsProduceEveryExpectedQueryItem() throws {
        let url = MotisQuery.url(for: request(.default))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.transitous.org")
        XCTAssertEqual(components.path, "/api/v6/plan")

        let q = try items(url)
        XCTAssertEqual(q["fromPlace"], "53.346500,-6.294300")
        XCTAssertEqual(q["toPlace"], "53.294600,-6.134000")
        XCTAssertEqual(q["time"], "2026-11-03T08:36:00Z")
        XCTAssertEqual(q["arriveBy"], "false")
        XCTAssertEqual(q["numItineraries"], "5")
        XCTAssertEqual(q["maxTransfers"], "2")
        XCTAssertEqual(q["maxPreTransitTime"], "600")
        XCTAssertEqual(q["maxPostTransitTime"], "600")
        XCTAssertEqual(q["transitModes"], "BUS,COACH,TRAM,RAIL")
        XCTAssertEqual(q["directModes"], "WALK,BIKE")
        XCTAssertEqual(q["maxDirectTime"], "2700")
        XCTAssertEqual(q.count, 11, "no unexpected items: \(q.keys.sorted())")
    }

    func testBikeOnAddsBikeDirectModeAndCap() throws {
        let q = try items(MotisQuery.url(for: request(prefs(bike: true))))
        XCTAssertEqual(q["directModes"], "WALK,BIKE")
        XCTAssertEqual(q["maxDirectTime"], "2700")
    }

    func testBikeOffWalksOnlyWithoutDirectCap() throws {
        let q = try items(MotisQuery.url(for: request(prefs(bike: false))))
        XCTAssertEqual(q["directModes"], "WALK")
        XCTAssertFalse(q.keys.contains("maxDirectTime"))
        XCTAssertEqual(q.count, 10)
    }

    func testNoTransitModesSendsEmptyTransitModes() throws {
        let url = MotisQuery.url(for: request(prefs(modes: [])))
        let q = try items(url)
        XCTAssertTrue(q.keys.contains("transitModes"))
        XCTAssertEqual(q["transitModes"], "")
        XCTAssertTrue(url.absoluteString.contains("transitModes=&") || url.absoluteString.hasSuffix("transitModes="),
                      url.absoluteString)
    }

    func testOnlyDartEnabledSendsRailOnly() throws {
        XCTAssertEqual(try items(MotisQuery.url(for: request(prefs(modes: [.dart]))))["transitModes"], "RAIL")
        XCTAssertEqual(try items(MotisQuery.url(for: request(prefs(modes: [.rail]))))["transitModes"], "RAIL")
        XCTAssertEqual(try items(MotisQuery.url(for: request(prefs(modes: [.dart, .rail]))))["transitModes"], "RAIL")
    }

    func testTransitModesOrderIsStable() {
        XCTAssertEqual(MotisQuery.transitModes([.rail, .luas, .bus, .dart]), "BUS,COACH,TRAM,RAIL")
        XCTAssertEqual(MotisQuery.transitModes([.luas]), "TRAM")
        XCTAssertEqual(MotisQuery.transitModes([.bus]), "BUS,COACH")
        XCTAssertEqual(MotisQuery.transitModes([.luas, .bus]), "BUS,COACH,TRAM")
        XCTAssertEqual(MotisQuery.transitModes([.walk, .bike]), "", "walk and bike are not transit")
        XCTAssertEqual(MotisQuery.transitModes([]), "")
    }

    func testArriveByWithSpecificTime() throws {
        // 2026-11-03T17:05:30Z, chosen with seconds so truncation would show.
        let arrival = Date(timeIntervalSince1970: 1_793_725_530)
        let req = JourneyRequest(origin: heuston, destination: dunLaoghaire, time: arrival,
                                 arriveBy: true, preferences: .default)
        let q = try items(MotisQuery.url(for: req))
        XCTAssertEqual(q["arriveBy"], "true")
        XCTAssertEqual(q["time"], "2026-11-03T17:05:30Z")
    }

    func testTimeIsAlwaysUTCWithoutFractionalSeconds() {
        XCTAssertEqual(MotisQuery.timestamp(Date(timeIntervalSince1970: 1_793_694_960.75)), "2026-11-03T08:36:00Z")
        XCTAssertEqual(MotisQuery.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
    }

    func testCoordinateFormattingUsesSixDecimalsAndPosixLocale() {
        XCTAssertEqual(MotisQuery.place(CLLocationCoordinate2D(latitude: 53.3, longitude: -6.25)), "53.300000,-6.250000")
        XCTAssertEqual(MotisQuery.place(CLLocationCoordinate2D(latitude: 53.34668399999999, longitude: -6.291857)),
                       "53.346684,-6.291857")
        XCTAssertEqual(MotisQuery.place(CLLocationCoordinate2D(latitude: -33.8688197, longitude: 151.2092957)),
                       "-33.868820,151.209296")
        XCTAssertEqual(MotisQuery.place(CLLocationCoordinate2D(latitude: 0, longitude: 0)), "0.000000,0.000000")
    }

    func testWalkToleranceAndTransfersFlowThrough() throws {
        let q = try items(MotisQuery.url(for: request(prefs(walk: 20, transfers: 0))))
        XCTAssertEqual(q["maxPreTransitTime"], "1200")
        XCTAssertEqual(q["maxPostTransitTime"], "1200")
        XCTAssertEqual(q["maxTransfers"], "0")
    }

    func testTransitModesOverrideReplacesPreferences() throws {
        var req = request(prefs(modes: [.bus, .luas, .dart, .rail]))
        req.transitModesOverride = [.luas, .dart, .rail]
        XCTAssertEqual(try items(MotisQuery.url(for: req))["transitModes"], "TRAM,RAIL")

        var busOnlyPrefs = request(prefs(modes: [.bus]))
        busOnlyPrefs.transitModesOverride = [.dart]
        XCTAssertEqual(try items(MotisQuery.url(for: busOnlyPrefs))["transitModes"], "RAIL",
                       "the override wins even over a set that excludes it")

        var walkOnly = request(.default)
        walkOnly.transitModesOverride = [.walk, .bike]
        XCTAssertEqual(try items(MotisQuery.url(for: walkOnly))["transitModes"], "")
        XCTAssertEqual(walkOnly.effectiveTransitModes, [])
    }

    func testWalkToleranceOverrideReplacesPreferences() throws {
        var req = request(prefs(walk: 10))
        req.walkToleranceOverrideMinutes = 20
        let q = try items(MotisQuery.url(for: req))
        XCTAssertEqual(q["maxPreTransitTime"], "1200")
        XCTAssertEqual(q["maxPostTransitTime"], "1200")
        XCTAssertEqual(req.effectiveWalkToleranceMinutes, 20)
        XCTAssertEqual(req.preferences.walkToleranceMinutes, 10, "the preference itself is untouched")

        req.walkToleranceOverrideMinutes = 5
        XCTAssertEqual(try items(MotisQuery.url(for: req))["maxPreTransitTime"], "300")
        XCTAssertEqual(q.count, 11, "overrides add no query items")
    }

    func testOverridesDefaultToNil() {
        let req = request(.default)
        XCTAssertNil(req.transitModesOverride)
        XCTAssertNil(req.walkToleranceOverrideMinutes)
        XCTAssertEqual(req.effectiveTransitModes, DirectionsPreferencesSnapshot.default.allowedTransitModes)
        XCTAssertEqual(req.effectiveWalkToleranceMinutes, 10)
        let explicit = JourneyRequest(origin: heuston, destination: dunLaoghaire, time: departure,
                                      preferences: .default, transitModesOverride: [.bus],
                                      walkToleranceOverrideMinutes: 15)
        XCTAssertEqual(explicit.transitModesOverride, [.bus])
        XCTAssertEqual(explicit.walkToleranceOverrideMinutes, 15)
    }

    func testNumItinerariesAndBaseOverride() throws {
        let base = URL(string: "http://localhost:8080/api/v6/plan")!
        let url = MotisQuery.url(for: request(.default), base: base, numItineraries: 8)
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 8080)
        XCTAssertEqual(try items(url)["numItineraries"], "8")
    }

    func testUserAgentFormat() throws {
        // NSBundle caches instances by path, so a stub must use a path no
        // Bundle has loaded yet or the override never runs.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stub-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(StubBundle(path: dir.path))
        XCTAssertTrue(type(of: bundle) == StubBundle.self, "got a cached \(type(of: bundle))")
        StubBundle.version = "1.2.3"
        let agent = MotisQuery.userAgent(bundle: bundle)
        XCTAssertEqual(agent, "BetterMaps/1.2.3 (https://github.com/gabrielconlon/betterMaps; gabe.conlon@gmail.com)")
        let pattern = #"^BetterMaps/[^ ]+ \(https://github\.com/gabrielconlon/betterMaps; gabe\.conlon@gmail\.com\)$"#
        XCTAssertNotNil(agent.range(of: pattern, options: .regularExpression), agent)

        StubBundle.version = nil
        XCTAssertEqual(MotisQuery.userAgent(bundle: bundle),
                       "BetterMaps/0 (https://github.com/gabrielconlon/betterMaps; gabe.conlon@gmail.com)")
        StubBundle.version = "1.2.3"

        XCTAssertNotNil(MotisQuery.userAgent().range(of: pattern, options: .regularExpression),
                        "main bundle also produces a well-formed agent")
    }

    func testLocalStopIdStripsFeedPrefix() {
        XCTAssertEqual(MotisQuery.localStopId("ie-transport-for-ireland_8220GA00387"), "8220GA00387")
        XCTAssertEqual(MotisQuery.localStopId("ie-transport-for-ireland_8220IR0007"), "8220IR0007")
        XCTAssertEqual(MotisQuery.localStopId("8220GA00387"), "8220GA00387", "no prefix: unchanged")
        XCTAssertEqual(MotisQuery.localStopId("feed_stop_with_underscores"), "stop_with_underscores",
                       "only the first underscore is a separator")
        XCTAssertEqual(MotisQuery.localStopId("_x"), "x")
        XCTAssertEqual(MotisQuery.localStopId("trailing_"), "")
        XCTAssertEqual(MotisQuery.localStopId(""), "")
    }
}
