import Foundation

/// How the rider wants a cycling route chosen. Each style maps to one
/// BRouter routing profile.
enum CyclingStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case quiet
    case balanced
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quiet: return "Quiet roads"
        case .balanced: return "Balanced"
        case .fast: return "Fastest"
        }
    }

    /// BRouter profile name: `safety` avoids busy roads, `trekking` is the
    /// general-purpose profile, `fastbike` minimises time.
    var brouterProfile: String {
        switch self {
        case .quiet: return "safety"
        case .balanced: return "trekking"
        case .fast: return "fastbike"
        }
    }

    var systemImage: String {
        switch self {
        case .quiet: return "leaf"
        case .balanced: return "scale.3d"
        case .fast: return "hare"
        }
    }
}
