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
    var failedModes: [TransportMode: String] = [:]
    var bicyclePreference: BicycleRoutePreference = .recommended
    var transitOptions: [TransitRouteOption] = []
    var isLoadingTransit = false
    var transitStatusMessage: String?  // Shows progress/errors for transit search
    var customDepartureTime: Date?  // nil = "now", set = future departure

    // Stored context for refreshes (so RoutingPanelView doesn't need to pass layers)
    private(set) var lastActiveTransitLayers: Set<TransitStop.TransitStopType> = []
    private var lastUserProfile: UserProfile?

    private let routingService = RoutingService()
    private let weatherService = WeatherDataService()
    private let bicycleService = BicycleRoutingService()
    private let transitPlanner = TransitRoutePlanner.shared
    private var routeCache: [RouteCacheKey: CachedRoute] = [:]

    func calculateRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        weatherRules: [WeatherRule],
        context: ModelContext? = nil,
        departureTime: Date = Date(),
        activeTransitLayers: Set<TransitStop.TransitStopType> = []
    ) async {
        isLoading = true
        errorMessage = nil
        activeRoutes = []
        failedModes = [:]

        let enabledRules = weatherRules.filter { $0.isEnabled }

        // Load user profile for mode preferences
        var userProfile: UserProfile?
        if let context {
            userProfile = try? context.fetch(FetchDescriptor<UserProfile>()).first
        }

        // Store context for refreshes and multi-stop routing
        lastUserProfile = userProfile
        lastActiveTransitLayers = activeTransitLayers

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
        // Skip modes the user has disabled in their profile
        for mode in TransportMode.mapKitModes where !(userProfile?.isModeDisabled(mode) ?? false) {
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

        // Cycling (independent, only if configured and not disabled)
        if BicycleRoutingService.isConfigured && !(userProfile?.isModeDisabled(.cycling) ?? false) {
            Task { @MainActor in
                await fetchCyclingRoute(
                    source: source,
                    destination: destination,
                    weather: currentWeather,
                    rules: enabledRules
                )
            }
        }

        // Multi-modal transit (GTFS-based, independent)
        if !(userProfile?.isModeDisabled(.transit) ?? false) {
            Task { @MainActor in
                isLoadingTransit = true
                transitStatusMessage = "Finding routes..."

                // GTFS schedule is pre-loaded at app startup; loadIfNeeded() is a no-op if already loaded
                // The planner calls it internally as a safety check
                let tripCount = await GTFSScheduleService.shared.tripCount

                if tripCount == 0 {
                    // Schedule not loaded yet (startup still in progress) — trigger load
                    await GTFSScheduleService.shared.loadIfNeeded()
                    let retryCount = await GTFSScheduleService.shared.tripCount
                    if retryCount == 0 {
                        transitStatusMessage = "GTFS schedule not available — check API Logs."
                        isLoadingTransit = false
                        return
                    }
                }

                // Pass all stops — findRoutes() handles distance filtering internally.
                // Pre-filtering by mode was dropping valid Luas/DART stops when bus stops
                // were closer, causing trips that should connect to show zero results.
                let allStops = await loadTransitStopsForPlanner()
                transitStatusMessage = "Searching routes..."

                let maxTransfers = userProfile?.maxTransfers ?? 1
                let transitPref = determineTransitPreference(
                    userProfile: userProfile, layers: activeTransitLayers
                )

                // Stream results as they're found — Luas/DART arrive first (fewer stops),
                // bus fills in after. No hard timeout needed since results appear incrementally.
                let allResults = await self.transitPlanner.findRoutes(
                    from: source, to: destination,
                    transitStops: allStops,
                    maxTransfers: maxTransfers,
                    transitPreference: transitPref,
                    departureTime: departureTime,
                    onRouteFound: { @Sendable route in
                        await MainActor.run {
                            // Add to displayed options immediately, sorted by preference
                            self.transitOptions.append(route)
                            let pref = transitPref
                            self.transitOptions.sort { a, b in
                                // Non-bus first when preferring tram/rail
                                if pref == "preferTramRail" {
                                    let aIsRail = a.primaryMode == .luas || a.primaryMode == .dart || a.primaryMode == .rail
                                    let bIsRail = b.primaryMode == .luas || b.primaryMode == .dart || b.primaryMode == .rail
                                    if aIsRail != bIsRail { return aIsRail }
                                }
                                return a.totalDuration < b.totalDuration
                            }
                            // Cap at 5 displayed
                            if self.transitOptions.count > 5 {
                                self.transitOptions = Array(self.transitOptions.prefix(5))
                            }
                            self.transitStatusMessage = nil
                        }
                    }
                )

                // Final pass: apply best-per-mode selection with favorites boost
                transitOptions = selectBestPerMode(
                    from: allResults, preference: transitPref,
                    favoriteRouteNames: userProfile?.favoriteRouteNames ?? [],
                    favoriteStopIds: userProfile?.favoriteStopIds ?? []
                )

                if transitOptions.isEmpty {
                    transitStatusMessage = "No transit routes found for this time."
                } else {
                    transitStatusMessage = nil
                }
                isLoadingTransit = false
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

    // MARK: - Mode-Aware Stop Selection

    /// Find the closest stops per mode near both origin and destination.
    /// Instead of sorting all 14K stops, we partition by type and pick the closest few per mode.
    /// Also includes a catch-all that picks closest stops of any type, ensuring misclassified
    /// Luas/DART stops (which may appear as bus in GTFS) are still considered.
    private func findNearbyStopsPerMode(
        allStops: [TransitStop],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> [TransitStop] {
        let originLoc = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let destLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)

        struct ModeConfig {
            let types: [TransitStop.TransitStopType]
            let radiusMeters: Double
            let maxCount: Int
        }

        let configs: [ModeConfig] = [
            ModeConfig(types: [.bus], radiusMeters: 800, maxCount: 5),
            ModeConfig(types: [.luas], radiusMeters: 1200, maxCount: 2),
            ModeConfig(types: [.dart], radiusMeters: 2000, maxCount: 2),
            ModeConfig(types: [.rail, .suburban], radiusMeters: 2000, maxCount: 2),
        ]

        var selectedIds = Set<String>()

        for loc in [originLoc, destLoc] {
            for config in configs {
                let modeStops = allStops
                    .filter { config.types.contains($0.type) }
                    .map { (stop: $0, dist: CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc)) }
                    .filter { $0.dist <= config.radiusMeters }
                    .sorted { $0.dist < $1.dist }
                    .prefix(config.maxCount)
                for match in modeStops {
                    selectedIds.insert(match.stop.id)
                }
            }

            // Catch-all: closest stops of ANY type within 1000m.
            // Ensures misclassified stops (e.g. Luas stop tagged as bus) are still considered.
            let closest = allStops
                .map { (stop: $0, dist: CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc)) }
                .filter { $0.dist <= 1000 }
                .sorted { $0.dist < $1.dist }
                .prefix(3)
            for match in closest {
                selectedIds.insert(match.stop.id)
            }
        }

        return allStops.filter { selectedIds.contains($0.id) }
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
        // Load user profile for sort preferences
        let profile: UserProfile? = {
            // Try to access from cache — sort is called frequently
            return nil // Will be set when calculateRoutes provides it
        }()

        activeRoutes.sort { a, b in
            // 1. User preference priority (preferred > normal > last-resort)
            if let profile {
                let aPriority = profile.modePriority(a.mode)
                let bPriority = profile.modePriority(b.mode)
                if aPriority != bPriority { return aPriority < bPriority }
            }
            // 2. Weather-preferred routes first
            if a.isPreferred != b.isPreferred { return a.isPreferred }
            // 3. Then by ETA
            return a.eta < b.eta
        }
    }

    func clearRoutes() {
        activeRoutes = []
        transitOptions = []
        errorMessage = nil
        failedModes = [:]
        customDepartureTime = nil
    }

    // MARK: - Transit Preference

    /// Determine transit preference from active layers on the map.
    /// Simple rule: layers ON = prioritize those modes. Layers OFF = fastest wins.
    /// Favorites boost within the ranking but don't override the layer-based preference.
    private func determineTransitPreference(
        userProfile: UserProfile?,
        layers: Set<TransitStop.TransitStopType>
    ) -> String {
        // No layers = no preference, sort by fastest
        if layers.isEmpty { return "fastest" }

        let hasTramRailLayers = layers.contains(.luas) || layers.contains(.dart) || layers.contains(.rail)
        let hasBusLayer = layers.contains(.bus)

        if hasTramRailLayers && !hasBusLayer { return "preferTramRail" }
        if hasBusLayer && !hasTramRailLayers { return "preferBus" }
        // Both on or other combos → fastest
        return "fastest"
    }

    /// Select best routes with mode diversity.
    /// When preferTramRail: non-bus routes ALWAYS appear first, then bus fills remaining slots.
    /// This matches the user's intent: toggling Luas/DART layers means "show me these first."
    private func selectBestPerMode(
        from options: [TransitRouteOption],
        preference: String,
        favoriteRouteNames: [String] = [],
        favoriteStopIds: [String] = []
    ) -> [TransitRouteOption] {
        guard !options.isEmpty else { return [] }

        // Deduplicate by summary + transfer count
        var seen = Set<String>()
        let unique = options.filter { seen.insert("\($0.summary)|\($0.transfers)").inserted }

        // Best per route (mode + route name) so Red/Green Luas both get slots
        var bestByRoute: [String: TransitRouteOption] = [:]
        for option in unique {
            let key = "\(option.primaryMode?.rawValue ?? "unknown")-\(option.summary)"
            if bestByRoute[key] == nil {
                bestByRoute[key] = option
            }
        }

        let all = Array(bestByRoute.values)
        let isPreferRail = preference == "preferTramRail"

        func isPreferred(_ option: TransitRouteOption) -> Bool {
            guard let mode = option.primaryMode else { return false }
            if isPreferRail { return mode == .luas || mode == .dart || mode == .rail }
            if preference == "preferBus" { return mode == .bus }
            return false
        }

        // Split into preferred and other, each sorted by duration
        let preferred = all.filter { isPreferred($0) }.sorted { $0.totalDuration < $1.totalDuration }
        let other = all.filter { !isPreferred($0) }.sorted { $0.totalDuration < $1.totalDuration }

        // Preferred routes ALWAYS come first, then fill with others
        var results: [TransitRouteOption] = []
        results.append(contentsOf: preferred)
        for option in other where results.count < 5 {
            results.append(option)
        }

        // Apply favorite boost within each group (re-sort preferred by favorites)
        if !favoriteRouteNames.isEmpty {
            results.sort { a, b in
                let aPreferred = isPreferred(a)
                let bPreferred = isPreferred(b)
                if aPreferred != bPreferred { return aPreferred }
                // Within same group, boost favorites
                let aSummary = a.summary.lowercased()
                let bSummary = b.summary.lowercased()
                let aFav = favoriteRouteNames.contains(where: { aSummary.contains($0.lowercased()) })
                let bFav = favoriteRouteNames.contains(where: { bSummary.contains($0.lowercased()) })
                if aFav != bFav { return aFav }
                return a.totalDuration < b.totalDuration
            }
        }

        return Array(results.prefix(5))
    }

    /// Load transit stops for the planner using ONLY GTFS stops.
    /// Hardcoded Luas stops (LUAS_* IDs) and Irish Rail API stops use IDs
    /// that don't exist in the GTFS stop_times table, so departuresFromStop()
    /// would never find any departures for them. GTFS stops have the correct
    /// stop_ids that match the schedule database.
    /// Also reclassifies stops using GTFS route_type for accurate mode selection.
    private func loadTransitStopsForPlanner() async -> [TransitStop] {
        var stops = await GTFSStopLoader().loadStops()

        // Reclassify stops using GTFS route_type + route_short_name.
        // Distinguishes DART (route_short_name='DART') from other rail (Commuter/InterCity).
        let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()
        if !classification.isEmpty {
            stops = stops.map { stop in
                guard let typeStr = classification[stop.id],
                      let newType = TransitStop.TransitStopType(rawValue: typeStr),
                      stop.type != newType else { return stop }
                return TransitStop(id: stop.id, name: stop.name,
                                   latitude: stop.latitude, longitude: stop.longitude,
                                   type: newType, stopCode: stop.stopCode)
            }
        }

        return stops
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
