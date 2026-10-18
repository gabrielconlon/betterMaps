import Foundation
import Observation

/// The tag selection that filters saved places: which tags are picked and
/// whether a place needs any or all of them. An empty selection shows every
/// place.
///
/// Persisted in UserDefaults:
/// - `tagFilterIds`: JSON array of uuid strings.
/// - `tagMatchMode`: `"any"` or `"all"` (`TagMatch.rawValue`; display
///   strings live in `TagMatch.title`).
///
/// Replaces `LayerFilterViewModel`, whose filter was "show the place layers
/// that are visible" plus an Any/All mode under `layerFilterMode`. The first
/// time tags are known, `migrateIfNeeded(tags:)` turns that state into an
/// equivalent selection so the map shows the same places after the upgrade.
@Observable
@MainActor
final class TagFilter {
    nonisolated static let idsKey = "tagFilterIds"
    nonisolated static let matchKey = "tagMatchMode"
    /// Pre-tags Any/All mode: "Any Layer" or "All Layers".
    nonisolated static let legacyModeKey = "layerFilterMode"
    nonisolated static let legacyAllValue = "All Layers"
    /// Set once the one-time migration has run.
    nonisolated static let migratedKey = "tagFilterMigrated"

    var selectedTagIds: Set<UUID> {
        didSet { if selectedTagIds != oldValue { persistIds() } }
    }

    var match: TagMatch {
        didSet { if match != oldValue { defaults.set(match.rawValue, forKey: Self.matchKey) } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedTagIds = Self.readIds(from: defaults)
        self.match = defaults.string(forKey: Self.matchKey).flatMap(TagMatch.init(rawValue:)) ?? .any
    }

    var hasSelection: Bool { !selectedTagIds.isEmpty }

    func isSelected(_ id: UUID) -> Bool { selectedTagIds.contains(id) }

    func toggle(_ id: UUID) {
        if selectedTagIds.contains(id) { selectedTagIds.remove(id) } else { selectedTagIds.insert(id) }
    }

    func clear() { selectedTagIds = [] }

    /// Drops ids of tags that no longer exist. Skipped while no tags are
    /// known, so a store that has not loaded yet cannot wipe the selection.
    func prune(existingTagIds: Set<UUID>) {
        guard !existingTagIds.isEmpty else { return }
        let kept = selectedTagIds.intersection(existingTagIds)
        if kept != selectedTagIds { selectedTagIds = kept }
    }

    /// One-time upgrade from per-layer visibility to a tag selection.
    ///
    /// - The selection becomes the tags that were visible, so the same places
    ///   show. If every tag or none was visible, the selection is empty
    ///   (show all).
    /// - Match is `.all` when the old mode was "All Layers", else `.any`.
    /// - The old key is removed and a flag stops it running again.
    ///
    /// Waits (does nothing) until at least one tag exists, so a store still
    /// syncing its first records is not migrated as "no tags".
    func migrateIfNeeded(tags: [LayerLite]) {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        let placeTags = tags.filter { $0.kind == .places }
        guard !placeTags.isEmpty else { return }

        let visible = Set(placeTags.filter(\.isVisible).map(\.id))
        selectedTagIds = visible.count == placeTags.count ? [] : visible
        match = defaults.string(forKey: Self.legacyModeKey) == Self.legacyAllValue ? .all : .any
        defaults.removeObject(forKey: Self.legacyModeKey)
        defaults.set(true, forKey: Self.migratedKey)
    }

    // MARK: - Persistence

    private func persistIds() {
        let raw = selectedTagIds.map(\.uuidString).sorted()
        if let data = try? JSONEncoder().encode(raw), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.idsKey)
        }
    }

    nonisolated static func readIds(from defaults: UserDefaults) -> Set<UUID> {
        guard let json = defaults.string(forKey: idsKey),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }
}
