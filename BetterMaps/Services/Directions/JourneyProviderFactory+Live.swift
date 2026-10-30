import Foundation

// stub; Builder A supplies the real one (the MOTIS / Transitous client).
extension JourneyProviderFactory {
    static func liveProvider() -> any JourneyProvider { FixtureJourneyProvider() }
}
