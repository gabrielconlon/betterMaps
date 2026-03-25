import SwiftUI
import MapKit
import WeatherKit
import Observation

struct RouteResult: Identifiable {
    let id = UUID()
    let mode: TransportMode
    let route: MKRoute
    let eta: TimeInterval
    let distance: CLLocationDistance
    let isPreferred: Bool
    let weatherWarning: String?
}

@Observable
@MainActor
class RoutingViewModel {
    var activeRoutes: [RouteResult] = []
    var isLoading = false
    var errorMessage: String?

    private let routingService = RoutingService()
    private let weatherService = WeatherDataService()

    func calculateRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        weatherRules: [WeatherRule]
    ) async {
        isLoading = true
        errorMessage = nil
        activeRoutes = []

        // Fetch routes and weather in parallel
        async let routeResults = routingService.calculateRoutes(from: source, to: destination)
        async let weather = weatherService.currentWeather(at: destination)

        let routes = await routeResults
        let currentWeather = await weather

        if routes.isEmpty {
            errorMessage = "No routes found."
            isLoading = false
            return
        }

        let enabledRules = weatherRules.filter { $0.isEnabled }

        var results: [RouteResult] = routes.map { mode, route in
            let warning = evaluateWeatherRules(
                rules: enabledRules,
                weather: currentWeather,
                mode: mode
            )
            let isSuppressed = shouldSuppress(
                rules: enabledRules,
                weather: currentWeather,
                mode: mode
            )

            return RouteResult(
                mode: mode,
                route: route,
                eta: route.expectedTravelTime,
                distance: route.distance,
                isPreferred: warning == nil && !isSuppressed,
                weatherWarning: warning
            )
        }

        // Remove suppressed routes
        results = results.filter { result in
            !shouldSuppress(
                rules: enabledRules,
                weather: currentWeather,
                mode: result.mode
            )
        }

        // Sort: preferred first, then by ETA
        results.sort { a, b in
            if a.isPreferred != b.isPreferred {
                return a.isPreferred
            }
            return a.eta < b.eta
        }

        activeRoutes = results
        isLoading = false
    }

    func clearRoutes() {
        activeRoutes = []
        errorMessage = nil
    }

    // MARK: - Weather Rule Evaluation

    private func evaluateWeatherRules(
        rules: [WeatherRule],
        weather: CurrentWeather?,
        mode: TransportMode
    ) -> String? {
        guard let weather else { return nil }

        let matchingRules = rules.filter {
            $0.suppressedMode == mode.rawValue && $0.actionType == "deprioritize"
        }

        for rule in matchingRules {
            if ruleTriggered(rule: rule, weather: weather) {
                return warningMessage(rule: rule, weather: weather)
            }
        }
        return nil
    }

    private func shouldSuppress(
        rules: [WeatherRule],
        weather: CurrentWeather?,
        mode: TransportMode
    ) -> Bool {
        guard let weather else { return false }

        let suppressRules = rules.filter {
            $0.suppressedMode == mode.rawValue && $0.actionType == "suppress"
        }

        return suppressRules.contains { ruleTriggered(rule: $0, weather: weather) }
    }

    private func ruleTriggered(rule: WeatherRule, weather: CurrentWeather) -> Bool {
        switch rule.conditionType {
        case "rain":
            let rainyConditions: [WeatherCondition] = [
                .rain, .heavyRain, .drizzle, .freezingRain,
                .sleet, .snow, .heavySnow, .blizzard
            ]
            return rainyConditions.contains(weather.condition)
        case "temperature":
            let tempF = weather.temperature.converted(to: .fahrenheit).value
            return tempF < rule.temperatureThresholdF
        case "wind":
            let windMPH = weather.wind.speed.converted(to: .milesPerHour).value
            return windMPH > rule.windSpeedThresholdMPH
        default:
            return false
        }
    }

    private func warningMessage(rule: WeatherRule, weather: CurrentWeather) -> String {
        switch rule.conditionType {
        case "rain":
            return "Precipitation expected (\(weather.condition.description))"
        case "temperature":
            let tempF = Int(weather.temperature.converted(to: .fahrenheit).value)
            return "Temperature is \(tempF)\u{00B0}F (below \(Int(rule.temperatureThresholdF))\u{00B0}F threshold)"
        case "wind":
            let windMPH = Int(weather.wind.speed.converted(to: .milesPerHour).value)
            return "Wind is \(windMPH) mph (above \(Int(rule.windSpeedThresholdMPH)) mph threshold)"
        default:
            return "Weather conditions not ideal"
        }
    }
}
