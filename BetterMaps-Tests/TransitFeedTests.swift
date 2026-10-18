import XCTest
@testable import CustomMapApp

/// Counts loader calls and lets a test move the clock.
private final class FeedStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _now = Date(timeIntervalSince1970: 1_700_000_000)

    var calls: Int { lock.withLock { _calls } }
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
    func hit() { lock.withLock { _calls += 1 } }
}

private func ok(_ url: URL, _ body: String, status: Int = 200) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private let stationsXML = """
<ArrayOfObjStation>
  <objStation>
    <StationDesc>Pearse</StationDesc><StationLatitude>53.3433</StationLatitude>
    <StationLongitude>-6.24914</StationLongitude><StationCode>PERSE</StationCode>
    <StationType>D</StationType>
  </objStation>
</ArrayOfObjStation>
"""

final class TransitFeedTests: XCTestCase {

    func testStationsAreCachedFor24Hours() async throws {
        let stub = FeedStub()
        let service = IrishRailService(
            load: { url in stub.hit(); return ok(url, stationsXML) },
            now: { stub.now },
            stationCache: IrishRailService.StationCache()
        )

        let first = try await service.stations()
        XCTAssertEqual(first.map(\.id), ["PERSE"])
        _ = try await service.stations()
        stub.advance(IrishRailService.stationCacheLifetime - 60)
        _ = try await service.stations()
        XCTAssertEqual(stub.calls, 1)

        stub.advance(120)
        _ = try await service.stations()
        XCTAssertEqual(stub.calls, 2)
    }

    func testTransportErrorMapsToUnavailable() async {
        let service = IrishRailService(
            load: { _ in throw URLError(.notConnectedToInternet) },
            stationCache: IrishRailService.StationCache()
        )
        do {
            _ = try await service.arrivals(stationCode: "PERSE")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .unavailable)
        }
        let fallback = await service.fetchStations()
        XCTAssertTrue(fallback.isEmpty)
    }

    func testHTTPErrorAndEmptyStationListAreNotCached() async {
        let stub = FeedStub()
        let service = IrishRailService(
            load: { url in stub.hit(); return ok(url, "<ArrayOfObjStation/>") },
            stationCache: IrishRailService.StationCache()
        )
        do {
            _ = try await service.stations()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .unavailable)
        }
        _ = await service.fetchStations()
        XCTAssertEqual(stub.calls, 2)

        let luas = LuasService(load: { url in ok(url, "Service Unavailable", status: 503) })
        do {
            _ = try await luas.forecast(stopCode: "STS")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .unavailable)
        }
        let none = await luas.fetchForecast(stopCode: "STS")
        XCTAssertNil(none)
    }
}
