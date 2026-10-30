import XCTest
import CoreLocation
@testable import CustomMapApp

/// Remembers the last request the provider sent.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?
    var request: URLRequest? { lock.withLock { _request } }
    func store(_ r: URLRequest) { lock.withLock { _request = r } }
}

private func http(_ request: URLRequest, status: Int, body: Data) -> (Data, URLResponse) {
    (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

final class MotisJourneyProviderTests: XCTestCase {
    private let heuston = CLLocationCoordinate2D(latitude: 53.3465, longitude: -6.2943)
    private let dunLaoghaire = CLLocationCoordinate2D(latitude: 53.2946, longitude: -6.1340)

    private func request(_ preferences: DirectionsPreferencesSnapshot = .default) -> JourneyRequest {
        JourneyRequest(origin: heuston, destination: dunLaoghaire,
                       time: Date(timeIntervalSince1970: 1_793_694_960), preferences: preferences)
    }

    private func provider(status: Int = 200, body: Data, box: RequestBox? = nil) -> MotisJourneyProvider {
        MotisJourneyProvider(loader: { request in
            box?.store(request)
            return http(request, status: status, body: body)
        })
    }

    private func failing(_ error: any Error) -> MotisJourneyProvider {
        MotisJourneyProvider(loader: { _ in throw error })
    }

    private func assertThrows(_ expected: JourneyProviderError, _ provider: MotisJourneyProvider,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let result = try await provider.plan(request())
            XCTFail("expected \(expected), got \(result.count) itineraries", file: file, line: line)
        } catch let error as JourneyProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected JourneyProviderError.\(expected), got \(error)", file: file, line: line)
        }
    }

    func testRequestCarriesUserAgentAndPlanPath() async throws {
        let box = RequestBox()
        let provider = provider(body: try MotisFixture.heuston.data(), box: box)
        let itineraries = try await provider.plan(request())
        XCTAssertEqual(itineraries.count, 3)

        let sent = try XCTUnwrap(box.request)
        let agent = try XCTUnwrap(sent.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(agent.hasPrefix("BetterMaps/"), agent)
        XCTAssertTrue(agent.contains("gabe.conlon@gmail.com"), agent)
        XCTAssertEqual(sent.url?.path, "/api/v6/plan")
        XCTAssertEqual(sent.url?.host, "api.transitous.org")
        XCTAssertEqual(sent.timeoutInterval, 20)
        XCTAssertEqual(sent.cachePolicy, .reloadIgnoringLocalCacheData)
        let items = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "fromPlace" }?.value, "53.346500,-6.294300")
    }

    func testCustomBaseURLIsUsed() async throws {
        let box = RequestBox()
        let data = try MotisFixture.empty.data()
        let provider = MotisJourneyProvider(
            loader: { request in box.store(request); return http(request, status: 200, body: data) },
            baseURL: URL(string: "http://localhost:8080/api/v6/plan")!)
        _ = try await provider.plan(request())
        XCTAssertEqual(box.request?.url?.host, "localhost")
        XCTAssertEqual(box.request?.url?.path, "/api/v6/plan")
    }

    func testRateLimitedStatus() async throws {
        await assertThrows(.rateLimited, provider(status: 429, body: Data("slow down".utf8)))
    }

    func testServerErrorStatus() async throws {
        await assertThrows(.unavailable(status: 503), provider(status: 503, body: Data()))
        await assertThrows(.unavailable(status: 404), provider(status: 404, body: Data("{}".utf8)))
    }

    func testMalformedBodyIsDecodingError() async throws {
        await assertThrows(.decoding, provider(body: Data("<html>not json</html>".utf8)))
        await assertThrows(.decoding, provider(body: Data(#"{"itineraries":[{"duration":"oops"}]}"#.utf8)))
    }

    func testTransportErrorIsUnavailableWithoutStatus() async throws {
        await assertThrows(.unavailable(status: nil), failing(URLError(.notConnectedToInternet)))
        await assertThrows(.unavailable(status: nil), failing(URLError(.timedOut)))
    }

    func testCancellationIsReportedAsCancelled() async throws {
        await assertThrows(.cancelled, failing(URLError(.cancelled)))
        await assertThrows(.cancelled, failing(CancellationError()))
    }

    func testDuplicateItinerariesCollapseToOne() async throws {
        // Repeat the server's itineraries verbatim: same trips, same times.
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MotisFixture.heuston.data()) as? [String: Any])
        let itineraries = try XCTUnwrap(json["itineraries"] as? [Any])
        json["itineraries"] = itineraries + itineraries
        let doubled = try JSONSerialization.data(withJSONObject: json)

        let result = try await provider(body: doubled).plan(request())
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
    }

    func testDuplicateHandBuiltResponseCollapses() {
        let t = Date(timeIntervalSince1970: 1_793_694_960)
        let leg = MotisLeg(mode: "BUS", from: MotisPlace(name: "A", lat: 53.3, lon: -6.2),
                           to: MotisPlace(name: "B", lat: 53.31, lon: -6.21),
                           duration: 600, startTime: t, endTime: t.addingTimeInterval(600),
                           tripId: "trip-1", legGeometry: MotisPolyline(points: ""))
        let itinerary = MotisItinerary(duration: 600, startTime: t, endTime: t.addingTimeInterval(600),
                                       transfers: 0, legs: [leg])
        let response = MotisPlanResponse(itineraries: [itinerary, itinerary], direct: [itinerary])
        let mapped = MotisMapper.itineraries(from: response, preferences: .default)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped.first?.id, "trip-1|1793694960|1793695560")
    }

    func testDisablingDartDropsDartItinerariesButKeepsRail() async throws {
        let prefs = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 10, enabledModes: [.bus, .luas, .rail], allowBikeDirect: true,
            maxTransfers: 2, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50)
        let result = try await provider(body: try MotisFixture.heuston.data()).plan(request(prefs))
        XCTAssertEqual(result.count, 1, "two DART itineraries dropped, the 'rail' one kept")
        XCTAssertEqual(result.first?.legs.map(\.mode), [.walk, .luas, .walk, .rail, .walk])
        XCTAssertEqual(result.first?.durationSeconds, 3000)
    }

    func testDisablingRailKeepsDartItineraries() async throws {
        let prefs = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 10, enabledModes: [.bus, .luas, .dart], allowBikeDirect: true,
            maxTransfers: 2, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50)
        let result = try await provider(body: try MotisFixture.heuston.data()).plan(request(prefs))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.transitLegs.contains { $0.mode == .dart } })
    }

    func testDisablingLuasDropsEverythingThatRidesIt() async throws {
        let prefs = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 10, enabledModes: [.bus, .dart, .rail], allowBikeDirect: true,
            maxTransfers: 2, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50)
        let result = try await provider(body: try MotisFixture.heuston.data()).plan(request(prefs))
        XCTAssertEqual(result, [])
    }

    func testTransitModesOverrideDrivesThePostFilter() async throws {
        // Bus-only preferences would drop every Heuston itinerary (they all
        // ride Luas + rail); a rail probe's override keeps them.
        let busOnly = DirectionsPreferencesSnapshot.default.replacing(enabledModes: [.bus])
        var probe = request(busOnly)
        probe.transitModesOverride = [.luas, .dart, .rail]
        let body = try MotisFixture.heuston.data()
        let kept = try await provider(body: body).plan(probe)
        XCTAssertEqual(kept.count, 3)
        let dropped = try await provider(body: body).plan(request(busOnly))
        XCTAssertEqual(dropped.count, 0, "without the override the same preferences drop them all")

        // And the other way: everything enabled, but the probe says bus only.
        var busProbe = request(.default)
        busProbe.transitModesOverride = [.bus]
        let busOnlyResults = try await provider(body: body).plan(busProbe)
        XCTAssertEqual(busOnlyResults, [])

        let response = try MotisFixture.heuston.response()
        XCTAssertEqual(MotisMapper.itineraries(from: response, preferences: busOnly, transitModesOverride: [.luas, .dart]).count, 2,
                       "DART only: the plain-rail itinerary is dropped")
        XCTAssertEqual(MotisMapper.itineraries(from: response, preferences: .default, transitModesOverride: nil).count, 3)
    }

    func testDirectBikeSurvivesTransitFilter() async throws {
        let prefs = DirectionsPreferencesSnapshot(
            walkToleranceMinutes: 10, enabledModes: [], allowBikeDirect: true,
            maxTransfers: 2, preferRail: true, preferRailWalkCeilingMinutes: 20,
            rainAware: true, rainProbabilityThreshold: 50)
        let result = try await provider(body: try MotisFixture.bikewalk.data()).plan(request(prefs))
        XCTAssertEqual(result.map { $0.legs.map(\.mode) }, [[.bike]], "no transit legs, nothing to filter")
    }

    func testResultsKeepTheEnginesOrderAndContent() async throws {
        // The provider does not rank: `DirectionsViewModel` does, once the
        // probes' answers are merged in. Transit first, direct after.
        let result = try await provider(body: try MotisFixture.heuston.data()).plan(request())
        XCTAssertEqual(result.map(\.durationSeconds).sorted(), [2820, 2880, 3000])
        XCTAssertEqual(result.map(\.durationSeconds), [2880, 3000, 2820], "the engine's own order")

        let mixed = try await provider(body: try MotisFixture.bikewalk.data()).plan(request())
        XCTAssertEqual(mixed.map(\.durationSeconds).sorted(), [3042, 4020, 4200, 4260])
        XCTAssertEqual(mixed.filter { $0.legs.map(\.mode) == [.bike] }.count, 1, "one direct cycle")
        XCTAssertTrue(mixed.allSatisfy { $0.reason == nil }, "no reasons until the view model ranks")
    }

    func testItineraryWithUnknownModeIsDroppedOthersKept() {
        let t = Date(timeIntervalSince1970: 1_793_694_960)
        func leg(_ mode: String, trip: String?, offset: Int) -> MotisLeg {
            MotisLeg(mode: mode, from: MotisPlace(name: "A", lat: 53.3, lon: -6.2),
                     to: MotisPlace(name: "B", lat: 53.31, lon: -6.21),
                     duration: 600, startTime: t.addingTimeInterval(TimeInterval(offset)),
                     endTime: t.addingTimeInterval(TimeInterval(offset + 600)),
                     tripId: trip, legGeometry: MotisPolyline(points: ""))
        }
        let busOnly = MotisItinerary(duration: 1200, startTime: t, endTime: t.addingTimeInterval(1200), transfers: 0,
                                     legs: [leg("WALK", trip: nil, offset: 0), leg("BUS", trip: "bus-1", offset: 600)])
        let viaFerry = MotisItinerary(duration: 1800, startTime: t, endTime: t.addingTimeInterval(1800), transfers: 1,
                                      legs: [leg("WALK", trip: nil, offset: 0), leg("FERRY", trip: "ferry-1", offset: 600),
                                             leg("BUS", trip: "bus-2", offset: 1200)])
        let byCar = MotisItinerary(duration: 900, startTime: t, endTime: t.addingTimeInterval(900), transfers: 0,
                                   legs: [leg("CAR", trip: nil, offset: 0)])
        let response = MotisPlanResponse(itineraries: [viaFerry, busOnly], direct: [byCar])
        let mapped = MotisMapper.itineraries(from: response, preferences: .default)
        XCTAssertEqual(mapped.map(\.id), ["WALK|bus-1|1793694960|1793696160"])
        XCTAssertEqual(mapped.first?.legs.map(\.mode), [.walk, .bus])
    }

    func testDateParserReadsBothIsoForms() {
        XCTAssertEqual(MotisDateParser.parse("2026-11-03T10:36:00Z"), Date(timeIntervalSince1970: 1_793_702_160))
        XCTAssertEqual(MotisDateParser.parse("2026-11-03T10:36:00.500Z"), Date(timeIntervalSince1970: 1_793_702_160.5))
        XCTAssertEqual(MotisDateParser.parse("2026-11-03T11:36:00+01:00"), Date(timeIntervalSince1970: 1_793_702_160))
        XCTAssertNil(MotisDateParser.parse("2026-11-03 10:36"))
        XCTAssertNil(MotisDateParser.parse(""))
    }

    func testEmptyResponseYieldsNoItineraries() async throws {
        let result = try await provider(body: try MotisFixture.empty.data()).plan(request())
        XCTAssertEqual(result, [])
    }
}
