import SwiftUI
import MapKit
import WeatherKit
import SwiftData
import Observation

struct RouteResult: Identifiable {
    let id = UUID()
    let mode: TransportMode
    let route: MKRoute?
    let cyclingPolyline: MKPolyline?
    let eta: TimeInterval
    let distance: CLLocationDistance
    let isPreferred: Bool
    let weatherWarning: String?
    let bikeLaneInfo: String?
    let isCached: Bool
    let cyclingSteps: [BicycleRouteStep]
}

// MARK: - Route Cache

struct RouteCacheKey: Hashable {
    let sourceLat: Double
    let sourceLng: Double
    let destLat: Double
    let destLng: Double
    let mode: TransportMode

    init(source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, mode: TransportMode) {
        // Round to ~100m precision for cache hits on similar locations
        self.sourceLat = (source.latitude * 1000).rounded() / 1000
        self.sourceLng = (source.longitude * 1000).rounded() / 1000
        self.destLat = (destination.latitude * 1000).rounded() / 1000
        self.destLng = (destination.longitude * 1000).rounded() / 1000
        self.mode = mode
    }
}

struct CachedRoute {
    let result: RouteResult
    let timestamp: Date
    let isSaved: Bool  // User explicitly saved = never expires
    var isExpired: Bool {
        if isSaved { return false }
        return Date().timeIntervalSince(timestamp) > 3600 // 1 hour TTL for auto-cache
    }
}

@Observable
@MainActor
class RoutingViewModel {
    var activeRoutes: [RouteResult] = []
    var isLoading = false
    var errorMessage: String?
    var failedModes: [TransportMode: String] = [:]  // mode -> reason
    var bicyclePreference: BicycleRoutePreference = .recommended

    private let routingService = RoutingService()
    private let weatherService = WeatherDataService()
    private let bicycleService = BicycleRoutingService()
    private var routeCache: [RouteCacheKey: CachedRoute] = [:]

    func calculateRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        weatherRules: [WeatherRule],
        context: ModelContext? = nil
    ) async {
        isLoading = true
        errorMessage = nil
        activeRoutes = []
        failedModes = [:]

        let enabledRules = weatherRules.filter { $0.isEnabled }

        // 1. Check persistent saved routes first (instant, no API calls)
        if let context {
            let savedResults = loadSavedRoutes(context: context, source: source, destination: destination)
            if !savedResults.isEmpty {
                activeRoutes = savedResults
                sortRoutes()
            }
        }

        // 2. Show in-memory cached results
        showCachedResults(source: source, destination: destination, rules: enabledRules)

        // Fetch weather (fast, needed for all routes)
        let currentWeather = await weatherService.currentWeather(at: destination)

        // Fire all route types as independent tasks — each streams in as it completes
        // MapKit modes: driving, walking, transit (each independent)
        for mode in TransportMode.mapKitModes {
            Task { @MainActor in
                await fetchMapKitRoute(
                    mode: mode,
                    source: source,
                    destination: destination,
                    weather: currentWeather,
                    rules: enabledRules
                )
            }
        }

        // Cycling (independent, only if configured)
        if BicycleRoutingService.isConfigured {
            Task { @MainActor in
                await fetchCyclingRoute(
                    source: source,
                    destination: destination,
                    weather: currentWeather,
                    rules: enabledRules
                )
            }
        }

        // Mark loading done after a brief delay for the fast routes to land
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            isLoading = false
            if activeRoutes.isEmpty {
                errorMessage = "No routes found."
            }
        }
    }

    // MARK: - Individual Route Fetchers (stream in as they complete)

    private func fetchMapKitRoute(
        mode: TransportMode,
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        weather: CurrentWeather?,
        rules: [WeatherRule]
    ) async {
        guard let transportType = mode.mkTransportType else { return }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType

        let directions = MKDirections(request: request)
        let route: MKRoute
        do {
            let response = try await directions.calculate()
            guard let first = response.routes.first else {
                failedModes[mode] = "No route available"
                return
            }
            route = first
        } catch {
            if mode == .transit {
                failedModes[mode] = "Apple Maps transit not available here. Use TFI for Irish transit."
            } else {
                failedModes[mode] = error.localizedDescription
            }
            return
        }

        if shouldSuppress(rules: rules, weather: weather, mode: mode) { return }

        let warning = evaluateWeatherRules(rules: rules, weather: weather, mode: mode)
        let result = RouteResult(
            mode: mode,
            route: route,
            cyclingPolyline: nil,
            eta: route.expectedTravelTime,
            distance: route.distance,
            isPreferred: warning == nil,
            weatherWarning: warning,
            bikeLaneInfo: nil,
            isCached: false,
            cyclingSteps: []
        )

        // Cache it
        let key = RouteCacheKey(source: source, destination: destination, mode: mode)
        routeCache[key] = CachedRoute(result: result, timestamp: Date(), isSaved: false)

        // Stream it in — replace any cached version for this mode
        activeRoutes.removeAll { $0.mode == mode }
        activeRoutes.append(result)
        sortRoutes()
    }

    private func fetchCyclingRoute(
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        weather: CurrentWeather?,
        rules: [WeatherRule]
    ) async {
        guard let bike = await bicycleService.calculateRoute(
            from: source, to: destination, preference: bicyclePreference
        ) else {
            failedModes[.cycling] = "Cycling route unavailable"
            return
        }

        if shouldSuppress(rules: rules, weather: weather, mode: .cycling) { return }

        let warning = evaluateWeatherRules(rules: rules, weather: weather, mode: .cycling)

        var bikeLaneInfo: String?
        var parts: [String] = []
        if bike.bikeLanePercentage > 0 { parts.append("\(Int(bike.bikeLanePercentage))% bike lanes") }
        if let surface = bike.surfaceInfo { parts.append(surface) }
        if !parts.isEmpty { bikeLaneInfo = parts.joined(separator: " · ") }

        let result = RouteResult(
            mode: .cycling,
            route: nil,
            cyclingPolyline: bike.polyline,
            eta: bike.duration,
            distance: bike.distance,
            isPreferred: warning == nil && bike.hasBikeLanes,
            weatherWarning: warning,
            bikeLaneInfo: bikeLaneInfo,
            isCached: false,
            cyclingSteps: bike.steps
        )

        let key = RouteCacheKey(source: source, destination: destination, mode: .cycling)
        routeCache[key] = CachedRoute(result: result, timestamp: Date(), isSaved: false)

        activeRoutes.removeAll { $0.mode == .cycling }
        activeRoutes.append(result)
        sortRoutes()
    }

    // MARK: - Cache

    private func showCachedResults(
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        rules: [WeatherRule]
    ) {
        for mode in TransportMode.allCases {
            let key = RouteCacheKey(source: source, destination: destination, mode: mode)
            if let cached = routeCache[key], !cached.isExpired {
                // Show cached result with isCached flag
                let cachedResult = RouteResult(
                    mode: cached.result.mode,
                    route: cached.result.route,
                    cyclingPolyline: cached.result.cyclingPolyline,
                    eta: cached.result.eta,
                    distance: cached.result.distance,
                    isPreferred: cached.result.isPreferred,
                    weatherWarning: cached.result.weatherWarning,
                    bikeLaneInfo: cached.result.bikeLaneInfo,
                    isCached: true,
                    cyclingSteps: cached.result.cyclingSteps
                )
                activeRoutes.append(cachedResult)
            }
        }
        if !activeRoutes.isEmpty {
            sortRoutes()
        }
    }

    private func sortRoutes() {
        activeRoutes.sort { a, b in
            if a.isPreferred != b.isPreferred { return a.isPreferred }
            return a.eta < b.eta
        }
    }

    func clearRoutes() {
        activeRoutes = []
        errorMessage = nil
        failedModes = [:]
    }

    /// Save current routes to SwiftData for true offline persistence.
    /// Routes survive app restarts and work without internet.
    func saveCurrentRoutes(
        context: ModelContext,
        originName: String,
        destinationName: String,
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) {
        for result in activeRoutes {
            // Extract coordinates from the route
            var coords: [CLLocationCoordinate2D] = []
            if let route = result.route {
                let pointCount = route.polyline.pointCount
                let points = route.polyline.points()
                for i in 0..<pointCount {
                    coords.append(points[i].coordinate)
                }
            } else if let polyline = result.cyclingPolyline {
                let pointCount = polyline.pointCount
                let points = polyline.points()
                for i in 0..<pointCount {
                    coords.append(points[i].coordinate)
                }
            }

            let saved = SavedRoute(
                name: "\(originName) → \(destinationName)",
                originName: originName,
                origin: source,
                destinationName: destinationName,
                destination: destination,
                mode: result.mode,
                etaSeconds: result.eta,
                distanceMeters: result.distance,
                coordinates: coords,
                bikeLaneInfo: result.bikeLaneInfo
            )
            context.insert(saved)
        }
    }

    /// Check SwiftData for previously saved routes that match this origin/destination
    func loadSavedRoutes(
        context: ModelContext,
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> [RouteResult] {
        let descriptor = FetchDescriptor<SavedRoute>()
        guard let allSaved = try? context.fetch(descriptor) else { return [] }

        // Match saved routes within ~200m of the requested endpoints
        let threshold = 0.002 // ~200m in degrees
        let matching = allSaved.filter { saved in
            abs(saved.originLatitude - source.latitude) < threshold &&
            abs(saved.originLongitude - source.longitude) < threshold &&
            abs(saved.destinationLatitude - destination.latitude) < threshold &&
            abs(saved.destinationLongitude - destination.longitude) < threshold
        }

        return matching.map { saved in
            let coords = saved.coordinates
            let polyline = MKPolyline(coordinates: coords, count: coords.count)

            // Update last used timestamp
            saved.lastUsed = Date()

            return RouteResult(
                mode: saved.transportMode,
                route: nil,
                cyclingPolyline: polyline,
                eta: saved.etaSeconds,
                distance: saved.distanceMeters,
                isPreferred: true,
                weatherWarning: nil,
                bikeLaneInfo: saved.bikeLaneInfo,
                isCached: true,
                cyclingSteps: []
            )
        }
    }

    // MARK: - Weather Rule Evaluation

    private func evaluateWeatherRules(
        rules: [WeatherRule],
        weather: CurrentWeather?,
        mode: TransportMode
    ) -> String? {
        guard let weather else { return nil }
        let matching = rules.filter { $0.suppressedMode == mode.rawValue && $0.actionType == "deprioritize" }
        for rule in matching {
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
        return rules
            .filter { $0.suppressedMode == mode.rawValue && $0.actionType == "suppress" }
            .contains { ruleTriggered(rule: $0, weather: weather) }
    }

    private func ruleTriggered(rule: WeatherRule, weather: CurrentWeather) -> Bool {
        switch rule.conditionType {
        case "rain":
            return [.rain, .heavyRain, .drizzle, .freezingRain, .sleet, .snow, .heavySnow, .blizzard]
                .contains(weather.condition)
        case "temperature":
            return weather.temperature.converted(to: .fahrenheit).value < rule.temperatureThresholdF
        case "wind":
            return weather.wind.speed.converted(to: .milesPerHour).value > rule.windSpeedThresholdMPH
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
