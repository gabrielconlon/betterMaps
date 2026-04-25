import SwiftUI
import SwiftData

@main
struct CustomMapAppApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Place.self,
            Layer.self,
            WeatherRule.self,
            SavedRoute.self,
            UserProfile.self,
            FavoriteTransitRoute.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    seedDefaultWeatherRules()
                    seedDefaultUserProfile()
                    // Load API keys from UserDefaults
                    if let key = UserDefaults.standard.string(forKey: "yelpAPIKey"), !key.isEmpty {
                        YelpService.apiKey = key
                    }
                    if let key = UserDefaults.standard.string(forKey: "orsAPIKey"), !key.isEmpty {
                        BicycleRoutingService.apiKey = key
                    }
                    if let key = UserDefaults.standard.string(forKey: "ntaAPIKey"), !key.isEmpty {
                        NTATransitService.apiKey = key
                    }
                    // Load cached route name lookup
                    GTFSStopLoader.loadCachedRouteNames()
                }
                .task {
                    // Pre-load GTFS stops cache if setup was already completed.
                    // First-time setup is handled by GTFSSetupView before the map appears.
                    if UserDefaults.standard.bool(forKey: "gtfsSetupComplete") {
                        _ = await GTFSStopLoader().loadStops()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private func seedDefaultWeatherRules() {
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<WeatherRule>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }

        let defaults = [
            WeatherRule(
                name: "Rain prefers driving",
                conditionType: "rain",
                suppressedMode: "walking",
                actionType: "deprioritize"
            ),
            WeatherRule(
                name: "Cold weather no walking",
                conditionType: "temperature",
                temperatureThresholdF: 32.0,
                suppressedMode: "walking",
                actionType: "deprioritize"
            ),
            WeatherRule(
                name: "High wind no walking",
                conditionType: "wind",
                windSpeedThresholdMPH: 25.0,
                suppressedMode: "walking",
                actionType: "deprioritize"
            ),
        ]

        for rule in defaults {
            context.insert(rule)
        }
    }

    private func seedDefaultUserProfile() {
        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<UserProfile>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }
        context.insert(UserProfile())
    }
}
