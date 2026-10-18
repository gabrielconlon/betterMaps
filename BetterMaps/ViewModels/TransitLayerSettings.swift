import Foundation
import Observation

/// The six map layers' switches (Places, Trails and the four transit
/// networks) and the user's pinned stops.
///
/// - `layers.showPlaces` / `layers.showTrails`: Bools, default true.
/// - `transit.enabledKinds`: JSON array of `TransitLayerKind` raw values,
///   stored as a string (`["bus","luas"]`).
/// - `transit.pinnedStopIds`: comma-joined stop ids (the format
///   `FavoriteStopButton` has always written, so existing pins survive).
///
/// On first init, the legacy `savedTransitStops` key (comma-joined
/// stop-type raw values, `suburban` included) is migrated into
/// `transit.enabledKinds` and deleted.
@Observable
@MainActor
final class TransitLayerSettings {
    static let shared = TransitLayerSettings()

    nonisolated static let enabledKindsKey = "transit.enabledKinds"
    nonisolated static let pinnedStopIdsKey = "transit.pinnedStopIds"
    nonisolated static let legacyEnabledKey = "savedTransitStops"
    nonisolated static let showPlacesKey = "layers.showPlaces"
    nonisolated static let showTrailsKey = "layers.showTrails"
    /// The kinds that were on when "Hide transit" turned them all off.
    nonisolated static let hiddenKindsKey = "transit.hiddenKinds"

    private(set) var enabledKinds: Set<TransitLayerKind> {
        didSet { if enabledKinds != oldValue { persistEnabledKinds() } }
    }

    var pinnedStopIds: [String] {
        didSet { if pinnedStopIds != oldValue { persistPinned() } }
    }

    /// The Places layer (saved place pins). Default on.
    var showPlaces: Bool {
        didSet { if showPlaces != oldValue { defaults.set(showPlaces, forKey: Self.showPlacesKey) } }
    }

    /// The Trails layer (trail lines and their endpoints). Default on.
    var showTrails: Bool {
        didSet { if showTrails != oldValue { defaults.set(showTrails, forKey: Self.showTrailsKey) } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pinnedStopIds = Self.decodePinned(defaults.string(forKey: Self.pinnedStopIdsKey) ?? "")
        self.showPlaces = defaults.object(forKey: Self.showPlacesKey) as? Bool ?? true
        self.showTrails = defaults.object(forKey: Self.showTrailsKey) as? Bool ?? true

        if let stored = Self.readEnabledKinds(from: defaults) {
            self.enabledKinds = stored
        } else if let legacy = defaults.string(forKey: Self.legacyEnabledKey) {
            self.enabledKinds = Self.decodeLegacy(legacy)
            persistEnabledKinds()
        } else {
            self.enabledKinds = []
        }
        // The legacy key is dead either way once the new one exists.
        if defaults.object(forKey: Self.legacyEnabledKey) != nil {
            defaults.removeObject(forKey: Self.legacyEnabledKey)
        }
    }

    // MARK: - Kinds

    func isEnabled(_ kind: TransitLayerKind) -> Bool { enabledKinds.contains(kind) }

    func toggle(_ kind: TransitLayerKind) {
        setEnabled(!isEnabled(kind), for: kind)
    }

    func setEnabled(_ on: Bool, for kind: TransitLayerKind) {
        if on { enabledKinds.insert(kind) } else { enabledKinds.remove(kind) }
    }

    func disableAll() { enabledKinds = [] }

    var isAnyTransitOn: Bool { !enabledKinds.isEmpty }

    /// "Hide transit": turns every network off and remembers which were on.
    func hideAllTransit() {
        guard !enabledKinds.isEmpty else { return }
        let raw = enabledKinds.map(\.rawValue).sorted().joined(separator: ",")
        defaults.set(raw, forKey: Self.hiddenKindsKey)
        enabledKinds = []
    }

    /// "Show transit": restores the networks "Hide transit" turned off, or
    /// all four when nothing was remembered.
    func showTransit() {
        let remembered = Set((defaults.string(forKey: Self.hiddenKindsKey) ?? "")
            .split(separator: ",").compactMap { TransitLayerKind(rawValue: String($0)) })
        enabledKinds = remembered.isEmpty ? Set(TransitLayerKind.allCases) : remembered
        defaults.removeObject(forKey: Self.hiddenKindsKey)
    }

    // MARK: - Pinned stops

    func isPinned(_ stopId: String) -> Bool { pinnedStopIds.contains(stopId) }

    func togglePinned(_ stopId: String) {
        if let i = pinnedStopIds.firstIndex(of: stopId) {
            pinnedStopIds.remove(at: i)
        } else {
            pinnedStopIds.append(stopId)
        }
    }

    // MARK: - Persistence

    private func persistEnabledKinds() {
        let raw = enabledKinds.map(\.rawValue).sorted()
        if let data = try? JSONEncoder().encode(raw), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.enabledKindsKey)
        }
    }

    private func persistPinned() {
        defaults.set(pinnedStopIds.joined(separator: ","), forKey: Self.pinnedStopIdsKey)
    }

    nonisolated static func readEnabledKinds(from defaults: UserDefaults) -> Set<TransitLayerKind>? {
        let data: Data?
        if let string = defaults.string(forKey: enabledKindsKey) {
            data = string.data(using: .utf8)
        } else {
            data = defaults.data(forKey: enabledKindsKey)
        }
        guard let data, let raw = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(raw.compactMap(TransitLayerKind.init(rawValue:)))
    }

    /// `"bus,dart,suburban"` → `[.bus, .dart, .rail]`.
    nonisolated static func decodeLegacy(_ raw: String) -> Set<TransitLayerKind> {
        Set(raw.split(separator: ",").compactMap { token -> TransitLayerKind? in
            let value = token.trimmingCharacters(in: .whitespaces)
            if value == "suburban" { return .rail }
            return TransitLayerKind(rawValue: value)
        })
    }

    nonisolated static func decodePinned(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}
