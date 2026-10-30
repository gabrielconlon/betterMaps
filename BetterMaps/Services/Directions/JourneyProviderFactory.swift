import Foundation

/// Picks the `JourneyProvider` the directions sheet plans with: the live
/// network client normally, the canned fixture under the UI-test flag. The
/// weather service follows the same switch so UI tests never reach
/// Open-Meteo.
enum JourneyProviderFactory {
    static let uiTestFlag = "-UITestFakeDirections"

    static func make() -> any JourneyProvider {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(uiTestFlag) {
            return FixtureJourneyProvider()
        }
        #endif
        return liveProvider()
    }

    /// The bike router: BRouter's public server normally, a synthetic route
    /// under the UI-test flag.
    static func makeCycling() -> any CyclingRouteProvider {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(uiTestFlag) {
            return FixtureCyclingProvider()
        }
        #endif
        return BRouterCyclingProvider()
    }

    static func makeWeather() -> WeatherHintService {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(uiTestFlag) {
            return WeatherHintService(loader: fixtureWeatherLoader)
        }
        #endif
        return WeatherHintService()
    }

    #if DEBUG
    /// A canned Open-Meteo answer: twelve hours from the current hour with
    /// rain most likely (80 %) two hours out, so the rain line shows in UI
    /// tests whatever the real sky is doing.
    static let fixtureWeatherLoader: WeatherHintService.Loader = { request in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let hourStart = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let times = (0..<12).map { formatter.string(from: hourStart.addingTimeInterval(TimeInterval($0) * 3600)) }
        let probabilities = [30, 60, 80, 70, 40, 20, 10, 10, 5, 5, 0, 0]
        let body: [String: Any] = [
            "hourly": ["time": times, "precipitation_probability": probabilities],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
    #endif
}
