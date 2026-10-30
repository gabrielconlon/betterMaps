import Foundation
/// Chooses the journey engine. Replaced wholesale by the UI builder's version at merge.
enum JourneyProviderFactory {
    static func make() -> any JourneyProvider { liveProvider() }
}
