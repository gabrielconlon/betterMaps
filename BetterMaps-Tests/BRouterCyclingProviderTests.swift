import XCTest
import CoreLocation
@testable import CustomMapApp

private final class BRouterRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?
    var request: URLRequest? { lock.withLock { _request } }
    func store(_ r: URLRequest) { lock.withLock { _request = r } }
}

private func brouterResponse(_ request: URLRequest, status: Int, body: Data) -> (Data, URLResponse) {
    (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

final class BRouterCyclingProviderTests: XCTestCase {
    private final class Anchor {}
    private static let fixtureName = "brouter_safety_rathmines_phoenix"

    private let rathmines = CLLocationCoordinate2D(latitude: 53.3263, longitude: -6.2650)
    private let phoenix = CLLocationCoordinate2D(latitude: 53.3560, longitude: -6.3300)
    private let departure = Date(timeIntervalSince1970: 1_793_694_960)

    private func request(_ style: CyclingStyle) -> CyclingRouteRequest {
        CyclingRouteRequest(origin: rathmines, destination: phoenix, style: style, departure: departure)
    }

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Anchor.self).url(forResource: Self.fixtureName, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func provider(status: Int = 200, body: Data, box: BRouterRequestBox? = nil) -> BRouterCyclingProvider {
        BRouterCyclingProvider(loader: { request in
            box?.store(request)
            return brouterResponse(request, status: status, body: body)
        })
    }

    private func assertThrows(_ expected: JourneyProviderError, _ provider: BRouterCyclingProvider,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.route(request(.quiet))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as JourneyProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected JourneyProviderError.\(expected), got \(error)", file: file, line: line)
        }
    }

    private func minimalGeoJSON(coordinates: String, totalTime: String = "\"120\"") -> Data {
        Data("""
        {"type":"FeatureCollection","features":[{"type":"Feature",
        "properties":{"track-length":"500","total-time":\(totalTime)},
        "geometry":{"type":"LineString","coordinates":\(coordinates)}}]}
        """.utf8)
    }

    // MARK: URL

    func testURLUsesProfilePerStyle() throws {
        let base = URL(string: "https://brouter.de/brouter")!
        let expected: [CyclingStyle: String] = [.quiet: "safety", .balanced: "trekking", .fast: "fastbike"]
        for style in CyclingStyle.allCases {
            let url = BRouterCyclingProvider.url(for: request(style), base: base)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            XCTAssertEqual(value("profile"), expected[style])
            XCTAssertEqual(value("alternativeidx"), "0")
            XCTAssertEqual(value("format"), "geojson")
            XCTAssertEqual(url.host, "brouter.de")
            XCTAssertEqual(url.path, "/brouter")
        }
    }

    func testLonlatsAreLonLatOrderSixDecimals() throws {
        let url = BRouterCyclingProvider.url(for: request(.quiet), base: URL(string: "https://brouter.de/brouter")!)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "lonlats" }?.value,
                       "-6.265000,53.326300|-6.330000,53.356000")
    }

    // MARK: Request

    func testRequestCarriesUserAgentAndTimeout() async throws {
        let box = BRouterRequestBox()
        _ = try await provider(body: try fixtureData(), box: box).route(request(.fast))
        let sent = try XCTUnwrap(box.request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), MotisQuery.userAgent())
        XCTAssertEqual(sent.timeoutInterval, 20)
        XCTAssertTrue(sent.url?.absoluteString.contains("profile=fastbike") == true)
    }

    // MARK: Decoding

    func testFixtureBecomesSingleBikeLeg() async throws {
        let data = try fixtureData()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let feature = try XCTUnwrap((json["features"] as? [[String: Any]])?.first)
        let coords = try XCTUnwrap((feature["geometry"] as? [String: Any])?["coordinates"] as? [[Double]])
        let props = try XCTUnwrap(feature["properties"] as? [String: Any])
        let totalTime = try XCTUnwrap(Int(try XCTUnwrap(props["total-time"] as? String)))

        let itinerary = try await provider(body: data).route(request(.quiet))
        XCTAssertEqual(itinerary.legs.count, 1)
        let leg = try XCTUnwrap(itinerary.legs.first)
        XCTAssertEqual(leg.mode, .bike)
        XCTAssertEqual(leg.coordinates.count, coords.count)
        XCTAssertEqual(leg.coordinates.first?.longitude, coords[0][0])
        XCTAssertEqual(leg.coordinates.first?.latitude, coords[0][1])
        XCTAssertEqual(itinerary.bikeSeconds, totalTime)
        XCTAssertEqual(itinerary.durationSeconds, totalTime)
        XCTAssertEqual(leg.durationSeconds, totalTime)
        XCTAssertEqual(itinerary.walkSeconds, 0)
        XCTAssertEqual(itinerary.transfers, 0)
        XCTAssertEqual(leg.start, departure)
        XCTAssertEqual(leg.end, departure.addingTimeInterval(TimeInterval(totalTime)))
        XCTAssertEqual(leg.fromName, "Start")
        XCTAssertEqual(leg.toName, "Destination")
        XCTAssertTrue(itinerary.id.hasPrefix("bike|quiet|1793694960|"))
    }

    func testReasonOnlyForQuietStyle() async throws {
        let data = try fixtureData()
        let quiet = try await provider(body: data).route(request(.quiet))
        let fast = try await provider(body: data).route(request(.fast))
        let balanced = try await provider(body: data).route(request(.balanced))
        XCTAssertEqual(quiet.reason, "Quiet roads")
        XCTAssertNil(fast.reason)
        XCTAssertNil(balanced.reason)
    }

    func testTwoElementCoordinatesDecode() async throws {
        let body = minimalGeoJSON(coordinates: "[[-6.26,53.33],[-6.27,53.34]]")
        let itinerary = try await provider(body: body).route(request(.quiet))
        XCTAssertEqual(itinerary.legs[0].coordinates.count, 2)
        XCTAssertEqual(itinerary.legs[0].coordinates[1].latitude, 53.34)
    }

    func testNumericTotalTimeDecodes() async throws {
        let body = minimalGeoJSON(coordinates: "[[-6.26,53.33,5],[-6.27,53.34,6]]", totalTime: "120")
        let itinerary = try await provider(body: body).route(request(.quiet))
        XCTAssertEqual(itinerary.bikeSeconds, 120)
    }

    // MARK: Errors

    func testRateLimited() async {
        await assertThrows(.rateLimited, provider(status: 429, body: Data()))
    }

    func testServerErrorCarriesStatus() async {
        await assertThrows(.unavailable(status: 503), provider(status: 503, body: Data()))
    }

    func testMalformedBodyIsDecodingError() async {
        await assertThrows(.decoding, provider(body: Data("brouter says no".utf8)))
        await assertThrows(.decoding, provider(body: Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)))
    }

    func testTransportFailureIsUnavailable() async {
        let failing = BRouterCyclingProvider(loader: { _ in throw URLError(.notConnectedToInternet) })
        await assertThrows(.unavailable(status: nil), failing)
    }

    func testCancellationIsCancelled() async {
        let cancelled = BRouterCyclingProvider(loader: { _ in throw URLError(.cancelled) })
        await assertThrows(.cancelled, cancelled)
    }
}
