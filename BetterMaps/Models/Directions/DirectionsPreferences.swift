import Foundation
import SwiftData

/// How the user likes to travel: walking tolerance, which networks to ride,
/// how many changes they will put up with. One row per user, synced through
/// iCloud like every other `@Model` here.
///
/// Every stored property has a default and there is no `@Attribute(.unique)`:
/// this app's ModelContainer mirrors to CloudKit, which rejects unique
/// constraints and requires defaults (see `FavoriteTransitRoute`). Because
/// there is no unique key, each device may insert its own row before the
/// first sync; `fetchOrCreate` collapses those to the newest.
@Model
final class DirectionsPreferences {
    /// How far the user will walk to or from a stop, 5/10/15/20.
    var walkToleranceMinutes: Int = 10
    /// `TransitMode.rawValue`s the planner may use. Stored as strings so a
    /// future mode does not need a migration.
    var enabledModesRaw: [String] = ["bus", "luas", "dart", "rail"]
    /// Offer a cycle-the-whole-way option alongside transit.
    var allowBikeDirect: Bool = true
    var maxTransfers: Int = 2
    /// Put a rail/DART option first when it exists and does not add more
    /// than `preferRailWalkCeilingMinutes` of walking.
    var preferRail: Bool = true
    var preferRailWalkCeilingMinutes: Int = 20
    /// Prefer options with less walking when rain is likely.
    var rainAware: Bool = true
    /// Rain probability (percent) above which `rainAware` kicks in.
    var rainProbabilityThreshold: Int = 50
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(snapshot: DirectionsPreferencesSnapshot = .default) {
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        apply(snapshot, at: now)
    }

    var snapshot: DirectionsPreferencesSnapshot {
        DirectionsPreferencesSnapshot(
            walkToleranceMinutes: walkToleranceMinutes,
            enabledModes: Set(enabledModesRaw.compactMap(TransitMode.init(rawValue:))),
            allowBikeDirect: allowBikeDirect,
            maxTransfers: maxTransfers,
            preferRail: preferRail,
            preferRailWalkCeilingMinutes: preferRailWalkCeilingMinutes,
            rainAware: rainAware,
            rainProbabilityThreshold: rainProbabilityThreshold
        )
    }

    /// Copies every field from `s` and bumps `updatedAt`. Does not save.
    func apply(_ s: DirectionsPreferencesSnapshot) {
        apply(s, at: Date())
    }

    private func apply(_ s: DirectionsPreferencesSnapshot, at date: Date) {
        walkToleranceMinutes = s.walkToleranceMinutes
        enabledModesRaw = s.enabledModes.map(\.rawValue).sorted()
        allowBikeDirect = s.allowBikeDirect
        maxTransfers = s.maxTransfers
        preferRail = s.preferRail
        preferRailWalkCeilingMinutes = s.preferRailWalkCeilingMinutes
        rainAware = s.rainAware
        rainProbabilityThreshold = s.rainProbabilityThreshold
        updatedAt = date
    }

    /// The single preferences row. Keeps the newest by `updatedAt` and deletes
    /// any extras CloudKit merged in from other devices; inserts a default row
    /// when there is none. Does not save; the caller does.
    @MainActor
    static func fetchOrCreate(in context: ModelContext) throws -> DirectionsPreferences {
        let descriptor = FetchDescriptor<DirectionsPreferences>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let rows = try context.fetch(descriptor)
        if let newest = rows.first {
            for extra in rows.dropFirst() { context.delete(extra) }
            return newest
        }
        let fresh = DirectionsPreferences()
        context.insert(fresh)
        return fresh
    }
}

/// Value copy of `DirectionsPreferences` for passing across actors and into
/// `JourneyRequest`. The initializer clamps every field to its valid range.
struct DirectionsPreferencesSnapshot: Sendable, Hashable, Codable {
    /// The walk tolerances the UI offers; other values snap to the nearest.
    static let walkToleranceSteps = [5, 10, 15, 20]

    let walkToleranceMinutes: Int
    let enabledModes: Set<TransitMode>
    let allowBikeDirect: Bool
    let maxTransfers: Int
    let preferRail: Bool
    let preferRailWalkCeilingMinutes: Int
    let rainAware: Bool
    let rainProbabilityThreshold: Int

    static let `default` = DirectionsPreferencesSnapshot(
        walkToleranceMinutes: 10,
        enabledModes: [.bus, .luas, .dart, .rail],
        allowBikeDirect: true,
        maxTransfers: 2,
        preferRail: true,
        preferRailWalkCeilingMinutes: 20,
        rainAware: true,
        rainProbabilityThreshold: 50
    )

    init(walkToleranceMinutes: Int, enabledModes: Set<TransitMode>, allowBikeDirect: Bool,
         maxTransfers: Int, preferRail: Bool, preferRailWalkCeilingMinutes: Int,
         rainAware: Bool, rainProbabilityThreshold: Int) {
        self.walkToleranceMinutes = Self.snapWalkTolerance(walkToleranceMinutes)
        self.enabledModes = enabledModes
        self.allowBikeDirect = allowBikeDirect
        self.maxTransfers = min(max(maxTransfers, 0), 4)
        self.preferRail = preferRail
        self.preferRailWalkCeilingMinutes = min(max(preferRailWalkCeilingMinutes, 0), 60)
        self.rainAware = rainAware
        self.rainProbabilityThreshold = min(max(rainProbabilityThreshold, 0), 100)
    }

    /// Nearest of 5/10/15/20; an exact midpoint (7.5 cannot occur with Ints,
    /// but 12 vs 13 can) rounds down to the smaller step.
    static func snapWalkTolerance(_ minutes: Int) -> Int {
        var best = walkToleranceSteps[0]
        for step in walkToleranceSteps where abs(step - minutes) < abs(best - minutes) {
            best = step
        }
        return best
    }

    /// `enabledModes` without walk/bike, which are never timetabled.
    var allowedTransitModes: Set<TransitMode> {
        enabledModes.filter(\.isTransit)
    }
}
