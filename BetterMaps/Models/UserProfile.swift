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

    // MARK: - Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {
        self.id = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Helpers

    /// Check if a TransportMode is disabled by the user
    func isModeDisabled(_ mode: TransportMode) -> Bool {
        disabledModes.contains(mode.rawValue)
    }

    /// Check if a TransportMode is preferred by the user
    func isModePreferred(_ mode: TransportMode) -> Bool {
        preferredModes.contains(mode.rawValue)
    }

    /// Check if a TransportMode is last-resort
    func isModeLastResort(_ mode: TransportMode) -> Bool {
        lastResortModes.contains(mode.rawValue)
    }

    /// Sort priority for a mode: 0 = preferred, 1 = normal, 2 = last resort
    func modePriority(_ mode: TransportMode) -> Int {
        if isModePreferred(mode) { return 0 }
        if isModeLastResort(mode) { return 2 }
        return 1
    }
}
