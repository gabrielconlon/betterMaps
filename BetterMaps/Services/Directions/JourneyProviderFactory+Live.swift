import Foundation

extension JourneyProviderFactory {
    /// The production engine: Transitous over the network.
    static func liveProvider() -> any JourneyProvider { MotisJourneyProvider() }
}
