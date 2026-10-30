import Foundation

/// Picks the `JourneyProvider` the directions sheet plans with: the live
/// network client normally, the canned fixture under the UI-test flag.
enum JourneyProviderFactory {
    static func make() -> any JourneyProvider {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestFakeDirections") {
            return FixtureJourneyProvider()
        }
        #endif
        return liveProvider()
    }
}
