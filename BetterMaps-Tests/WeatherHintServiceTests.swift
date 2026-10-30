import XCTest
import CoreLocation
@testable import CustomMapApp

/// Hand-written Open-Meteo answers under `Fixtures/weather/`, twelve UTC
/// hours on 2027-01-15 from 06:00. The rainy one peaks at 80 % at 12:00.
enum WeatherFixture: String {
    case rain = "open_meteo_hourly_rain"
    case dry = "open_meteo_hourly_dry"

    private final class Anchor {}

    func data(file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Anchor.self).url(forResource: rawValue, withExtension: "json"),
            "fixture \(rawValue).json missing from test bundle", file: file, line: line)
        return try Data(contentsOf: url)
    }
}

/// Records every request the service sent and answers each by latitude.
final class WeatherLoaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    var count: Int { requests.count }
    func record(_ request: URLRequest) { lock.withLock { _requests.append(request) } }

    static func query(_ request: URLRequest) -> [String: String?] {
        var result: [String: String?] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}

/// An HTTP answer for a stubbed loader. A free function so loader closures
/// capture nothing but their data.
func weatherHTTP(_ request: URLRequest, status: Int = 200, body: Data) -> (Data, URLResponse) {
    (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

final class WeatherHintServiceTests: XCTestCase {
    /// Heuston rounds to (53.35, -6.29); Dún Laoghaire to (53.29, -6.14).
    private let heuston = CLLocationCoordinate2D(latitude: 53.3464, longitude: -6.2923)
    private let dunLaoghaire = CLLocationCoordinate2D(latitude: 53.2938, longitude: -6.1353)

    /// 2027-01-15T08:00:00Z
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func hour(_ h: Int) -> Date { t0.addingTimeInterval(TimeInterval(h - 8) * 3600) }

    /// A service answering `rain` for Heuston's cell and `dry` elsewhere.
    private func service(box: WeatherLoaderBox, now: @escaping @Sendable () -> Date = { Date() },
                         heustonBody: Data, otherBody: Data) -> WeatherHintService {
        WeatherHintService(loader: { request in
            box.record(request)
            let lat = WeatherLoaderBox.query(request)["latitude"] ?? nil
            return weatherHTTP(request, body: lat == "53.3500" ? heustonBody : otherBody)
        }, now: now)
    }

    private func hint(_ service: WeatherHintService, window: ClosedRange<Date>, threshold: Int = 50) async -> RainHint? {
        await service.hint(origin: heuston, destination: dunLaoghaire,
                           originName: "Heuston", destinationName: "Dún Laoghaire",
                           window: window, threshold: threshold)
    }

    // MARK: Request shape

    func testRequestTargetsOpenMeteoWithExpectedQueryAndUserAgent() async throws {
        let box = WeatherLoaderBox()
        let service = service(box: box, heustonBody: try WeatherFixture.rain.data(), otherBody: try WeatherFixture.dry.data())
        _ = await hint(service, window: hour(11)...hour(13))

        XCTAssertEqual(box.count, 2, "one request per point")
        let sent = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(sent.url?.scheme, "https")
        XCTAssertEqual(sent.url?.host, "api.open-meteo.com")
        XCTAssertEqual(sent.url?.path, "/v1/forecast")
        let q = WeatherLoaderBox.query(sent)
        XCTAssertEqual(q["latitude"], "53.3500")
        XCTAssertEqual(q["longitude"], "-6.2900")
        XCTAssertEqual(q["hourly"], "precipitation_probability,precipitation,weather_code")
        XCTAssertEqual(q["forecast_hours"], "12")
        XCTAssertEqual(q["timezone"], "UTC")
        XCTAssertEqual(q.count, 5, "no unexpected items: \(q.keys.sorted())")
        let agent = try XCTUnwrap(sent.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(agent.hasPrefix("BetterMaps/"), agent)
        XCTAssertTrue(agent.contains("gabe.conlon@gmail.com"), agent)
        XCTAssertEqual(sent.cachePolicy, .reloadIgnoringLocalCacheData)

        let second = WeatherLoaderBox.query(box.requests[1])
        XCTAssertEqual(second["latitude"], "53.2900")
        XCTAssertEqual(second["longitude"], "-6.1400")
    }

    // MARK: Hints

    func testHintNamesWettestPointAndHour() async throws {
        let box = WeatherLoaderBox()
        // Rain at the destination this time, so the name must follow the data.
        let service = service(box: box, heustonBody: try WeatherFixture.dry.data(), otherBody: try WeatherFixture.rain.data())
        let hint = await hint(service, window: hour(10)...hour(14))
        XCTAssertEqual(hint, RainHint(probabilityPercent: 80, hour: hour(12), nearName: "Dún Laoghaire"))
    }

    func testHintPrefersOriginOnTieAndRespectsThreshold() async throws {
        let box = WeatherLoaderBox()
        let service = service(box: box, heustonBody: try WeatherFixture.rain.data(), otherBody: try WeatherFixture.rain.data())
        let tied = await hint(service, window: hour(10)...hour(14))
        XCTAssertEqual(tied?.nearName, "Heuston")
        XCTAssertEqual(tied?.probabilityPercent, 80)

        let tooHigh = await hint(service, window: hour(10)...hour(14), threshold: 90)
        XCTAssertNil(tooHigh, "80 < 90")
        let exact = await hint(service, window: hour(10)...hour(14), threshold: 80)
        XCTAssertNotNil(exact, "threshold is inclusive")
    }

    func testDryForecastGivesNoHint() async throws {
        let box = WeatherLoaderBox()
        let service = service(box: box, heustonBody: try WeatherFixture.dry.data(), otherBody: try WeatherFixture.dry.data())
        let allDay = await hint(service, window: hour(6)...hour(17))
        XCTAssertNil(allDay)
        let lowBar = await hint(service, window: hour(6)...hour(17), threshold: 20)
        XCTAssertNil(lowBar, "15 is the dry peak")
    }

    func testWindowIsWidenedAnHourEachWay() async throws {
        let box = WeatherLoaderBox()
        let service = service(box: box, heustonBody: try WeatherFixture.rain.data(), otherBody: try WeatherFixture.dry.data())
        // Departing 12:30: the 12:00 hour started before departure but is
        // still the shower you walk out into.
        let justAfterPeak = hour(12).addingTimeInterval(30 * 60)...hour(12).addingTimeInterval(45 * 60)
        let departingInto = await hint(service, window: justAfterPeak)
        XCTAssertEqual(departingInto?.hour, hour(12))

        // Arriving 11:00: 12:00 is within the hour after arrival, so it counts.
        let arrivingBefore = await hint(service, window: hour(9)...hour(11))
        XCTAssertEqual(arrivingBefore?.hour, hour(12))

        // Arriving 10:30: the padding reaches 11:30, before the 12:00 hour.
        let early = await hint(service, window: hour(8)...hour(10).addingTimeInterval(30 * 60), threshold: 50)
        XCTAssertEqual(early?.probabilityPercent, 60, "11:00 is the peak in reach")
        let morning = await hint(service, window: hour(6)...hour(8))
        XCTAssertNil(morning, "7:00-9:00 peaks at 30")
    }

    func testPeakIsPureAndSkipsMissingValues() {
        let hours = [
            WeatherHintService.ForecastHour(time: hour(9), probability: nil),
            WeatherHintService.ForecastHour(time: hour(10), probability: 40),
            WeatherHintService.ForecastHour(time: hour(11), probability: 70),
            WeatherHintService.ForecastHour(time: hour(12), probability: 70),
        ]
        let peak = WeatherHintService.peak(in: hours, window: hour(9)...hour(12))
        XCTAssertEqual(peak?.probability, 70)
        XCTAssertEqual(peak?.time, hour(11), "earlier hour wins a tie")
        XCTAssertNil(WeatherHintService.peak(in: [hours[0]], window: hour(9)...hour(9)))
        XCTAssertNil(WeatherHintService.peak(in: [], window: hour(9)...hour(12)))
    }

    func testParseReadsUTCHoursAndNulls() throws {
        let hours = try WeatherHintService.parse(try WeatherFixture.dry.data())
        XCTAssertEqual(hours.count, 12)
        XCTAssertEqual(hours.first?.time, hour(6))
        XCTAssertEqual(hours.last?.time, hour(17))
        XCTAssertEqual(hours.last?.probability, nil, "trailing null is kept as nil")
        XCTAssertEqual(hours[6].probability, 15)
    }

    // MARK: Failures and the cache

    func testServerErrorWithEmptyCacheGivesNil() async {
        let box = WeatherLoaderBox()
        let service = WeatherHintService(loader: { request in
            box.record(request)
            return weatherHTTP(request, status: 500, body: Data())
        })
        let result = await hint(service, window: hour(10)...hour(14))
        XCTAssertNil(result)
        XCTAssertEqual(box.count, 2)
    }

    func testTransportErrorAndGarbageGiveNil() async {
        let failing = WeatherHintService(loader: { _ in throw URLError(.notConnectedToInternet) })
        let offline = await hint(failing, window: hour(10)...hour(14))
        XCTAssertNil(offline)
        let garbage = WeatherHintService(loader: { request in weatherHTTP(request, body: Data("<html>".utf8)) })
        let undecodable = await hint(garbage, window: hour(10)...hour(14))
        XCTAssertNil(undecodable)
    }

    func testCacheServesWithinThirtyMinutesAndStaleAfterFailure() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var _now = Date(timeIntervalSince1970: 1_800_000_000)
            var now: Date { lock.withLock { _now } }
            func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
        }
        final class Switch: @unchecked Sendable {
            private let lock = NSLock()
            private var _failing = false
            var failing: Bool {
                get { lock.withLock { _failing } }
                set { lock.withLock { _failing = newValue } }
            }
        }
        let clock = Clock()
        let toggle = Switch()
        let box = WeatherLoaderBox()
        let rain = try WeatherFixture.rain.data()
        let service = WeatherHintService(loader: { request in
            box.record(request)
            if toggle.failing { return weatherHTTP(request, status: 503, body: Data()) }
            return weatherHTTP(request, body: rain)
        }, now: { clock.now })

        let first = await hint(service, window: hour(10)...hour(14))
        XCTAssertNotNil(first)
        XCTAssertEqual(box.count, 2)

        clock.advance(29 * 60)
        let cached = await hint(service, window: hour(10)...hour(14))
        XCTAssertNotNil(cached)
        XCTAssertEqual(box.count, 2, "fresh cache: no new request")

        clock.advance(2 * 60)
        toggle.failing = true
        let stale = await hint(service, window: hour(10)...hour(14))
        XCTAssertEqual(box.count, 4, "expired: refresh attempted for both points")
        XCTAssertEqual(stale?.probabilityPercent, 80, "the stale forecast still answers")

        toggle.failing = false
        let refreshed = await hint(service, window: hour(10)...hour(14))
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(box.count, 6, "a failed refresh does not extend the cache")
    }

    func testSamePointIsFetchedOnce() async throws {
        let box = WeatherLoaderBox()
        let rain = try WeatherFixture.rain.data()
        let service = WeatherHintService(loader: { request in
            box.record(request)
            return weatherHTTP(request, body: rain)
        })
        // (53.3484, -6.2903) still rounds to (53.35, -6.29).
        let nearby = CLLocationCoordinate2D(latitude: heuston.latitude + 0.002, longitude: heuston.longitude + 0.002)
        let hint = await service.hint(origin: heuston, destination: nearby, originName: "A", destinationName: "B",
                                      window: hour(10)...hour(14), threshold: 50)
        XCTAssertEqual(box.count, 1, "both ends round to the same cell")
        XCTAssertEqual(hint?.nearName, "A")
    }
}
