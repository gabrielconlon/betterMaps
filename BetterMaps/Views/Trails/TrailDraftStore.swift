import Foundation
import Observation

/// A trail draft the user chose to keep when leaving the editor.
struct PendingDraft: Codable, Equatable, Sendable {
    var layerId: UUID
    /// nil when the draft is a new trail.
    var trailId: UUID?
    var draft: TrailDraft
    var savedAt: Date

    init(layerId: UUID, trailId: UUID?, draft: TrailDraft, savedAt: Date = Date()) {
        self.layerId = layerId
        self.trailId = trailId
        self.draft = draft
        self.savedAt = savedAt
    }
}

/// Holds at most one kept trail draft and persists it to UserDefaults so it
/// survives relaunch. The map shows a "Draft trail · Resume" chip from
/// `pending`; `TrailEditorView` resumes it automatically when opened for the
/// same layer and trail.
@Observable
@MainActor
final class TrailDraftStore {
    static let shared = TrailDraftStore()
    static let defaultsKey = "trail.draft.v1"

    private(set) var pending: PendingDraft?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            pending = try? JSONDecoder().decode(PendingDraft.self, from: data)
        }
    }

    var hasDraft: Bool { pending != nil }

    /// Replaces any kept draft with this one.
    func save(_ draft: TrailDraft, layerId: UUID, trailId: UUID?) {
        let value = PendingDraft(layerId: layerId, trailId: trailId, draft: draft)
        pending = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func clear() {
        pending = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// The kept draft for exactly this layer/trail pair, if any.
    func pending(layerId: UUID, trailId: UUID?) -> PendingDraft? {
        guard let p = pending, p.layerId == layerId, p.trailId == trailId else { return nil }
        return p
    }

    /// Clears the kept draft only if it belongs to this layer/trail pair.
    func clear(layerId: UUID, trailId: UUID?) {
        if pending(layerId: layerId, trailId: trailId) != nil { clear() }
    }
}
