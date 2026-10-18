import SwiftUI
import SwiftData
import os

/// Builds the app's SwiftData container. Kept separate from the `App` so
/// tests can exercise the exact schema the app ships with.
enum AppModelContainer {
    /// Every persisted entity. Dropping an entity here is a lightweight
    /// migration (see `SchemaUpgradeTests`); renaming one is not.
    static let schema = Schema([
        Place.self,
        Layer.self,
        Trail.self,
        FavoriteTransitRoute.self
    ])

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "storage"
    )

    /// CloudKit-backed store first so saved places sync between the user's
    /// devices. If that throws (no iCloud account, container misconfigured,
    /// cloud-side schema rejected), fall back to the same on-disk store
    /// without sync. If even that fails, launch with an in-memory store so
    /// the UI still comes up; nothing is persisted in that mode.
    static func make() -> ModelContainer {
        do {
            let cloud = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
            return try ModelContainer(for: schema, configurations: [cloud])
        } catch {
            logger.error("CloudKit store failed, falling back to local-only: \(String(describing: error), privacy: .public)")
        }

        do {
            let local = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            logger.fault("Local store failed too, running in memory; changes will NOT be saved: \(String(describing: error), privacy: .public)")
        }

        do {
            let memory = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [memory])
        } catch {
            // An in-memory store over a compiled-in schema cannot realistically
            // fail; if it does, the binary itself is broken.
            logger.fault("In-memory store failed: \(String(describing: error), privacy: .public)")
            preconditionFailure("BetterMaps could not create any SwiftData store: \(error)")
        }
    }
}

@main
struct CustomMapAppApp: App {
    let sharedModelContainer: ModelContainer = AppModelContainer.make()

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
