import Foundation
import SwiftData

/// Persistent user preferences for routing and transport modes.
/// Separate from map view state (layers/filters) — this is "who I am",
/// not "what I'm looking at right now."
@Model
final class UserProfile {
    var id: UUID = UUID()

    // MARK: - Mode Preferences

    /// Modes the user never wants shown (e.g., ["driving"] if no car)
    var disabledModes: [String] = []

    /// Modes to prioritize in results (shown first, e.g., ["cycling", "transit"])
    var preferredModes: [String] = []

    /// Modes to show last / only as fallback (e.g., ["walking"] in bad weather)
    var lastResortModes: [String] = []

    // MARK: - Transit Preferences

    /// Maximum number of transfers in transit routes
    var maxTransfers: Int = 2

    /// Transit mode preference: "fastest" (default), "preferTramRail", "preferBus"
    var transitModePreference: String = "fastest"

    /// Favorite transit stop IDs — routes through these get a priority boost
    var favoriteStopIds: [String] = []

    /// Favorite route names — these routes always appear if available (e.g. "Red", "DART")
    var favoriteRouteNames: [String] = []

    // MARK: - Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {
        self.id = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
