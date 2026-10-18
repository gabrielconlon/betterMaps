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
        // Try CloudKit-backed first so saved places sync between the user's
        // devices. If the cloud-side schema migration fails (which can hang
        // ModelContainer.init indefinitely after a schema change like adding
        // FavoriteTransitRoute / pathId / sortIndex / pathNamesJSON), fall
        // back to a local-only store so the app still launches. The user
        // reported a hard white-screen hang with no log progress past the
        // initial GTFS route lookup — exactly the signature of a failed
        // CloudKit init blocking the WindowGroup body.
        let cloudConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: [cloudConfig])
        } catch {
            print("[BetterMaps] CloudKit ModelContainer failed (\(error.localizedDescription)) — falling back to local-only")
            let localConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            do {
                return try ModelContainer(for: schema, configurations: [localConfig])
            } catch {
                fatalError("Could not create local ModelContainer either: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    if let key = UserDefaults.standard.string(forKey: "yelpAPIKey"), !key.isEmpty {
                        YelpService.apiKey = key
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
