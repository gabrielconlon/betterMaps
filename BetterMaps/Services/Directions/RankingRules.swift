import Foundation

/// Inputs that shape the order of itineraries beyond raw duration.
struct RankingContext: Sendable {
    var preferRail: Bool = false
    /// Walking at the two ends a rail option may total and still be pinned
    /// first.
    var railWalkCeilingSeconds: Int = 1200
    /// The user's walk limit, used for sorting only: walking beyond it costs
    /// double. Nil when they will walk any distance.
    var walkToleranceSeconds: Int? = nil
    /// Networks (and bike) the user has on. The fastest option on each is
    /// kept in the list whatever its cost.
    var enabledModes: Set<TransitMode> = []

    init(preferRail: Bool = false, railWalkCeilingSeconds: Int = 1200,
         walkToleranceSeconds: Int? = nil, enabledModes: Set<TransitMode> = []) {
        self.preferRail = preferRail
        self.railWalkCeilingSeconds = railWalkCeilingSeconds
        self.walkToleranceSeconds = walkToleranceSeconds
        self.enabledModes = enabledModes
    }
}

/// Orders a provider's itineraries for the directions sheet.
enum RankingRules {
    static let railReason = "Rail"
    static let fastestByPrefix = "Fastest by "
    /// The most options the sheet lists.
    static let maxResults = 8

    /// Networks that count as "rail" for the pin: trams included, since Luas
    /// is how most people reach a DART station from the city centre.
    static let railModes: Set<TransitMode> = [.luas, .dart, .rail]

    /// Modes a "Fastest by" guarantee can name, in the order ties are broken.
    static let guaranteedModes: [TransitMode] = [.bus, .luas, .dart, .rail, .bike]

    /// "Fastest by DART" and so on.
    static func fastestReason(_ mode: TransitMode) -> String {
        fastestByPrefix + mode.displayName
    }

    /// Pure and deterministic:
    /// 1. Each option's cost is its duration plus double whatever walking
    ///    exceeds the user's limit (none when they will walk any distance).
    /// 2. With `preferRail`, options that ride only rail modes and whose
    ///    walking at the two ends stays within the ceiling come first, by
    ///    cost, tagged "Rail".
    /// 3. Everything else follows by cost, then duration, then start time,
    ///    then input order.
    /// 4. For every enabled mode the fastest option riding it stays in the
    ///    list, however it scored, tagged "Fastest by <mode>" unless it is
    ///    the first row (nothing to explain) or already the rail pin.
    /// 5. The list is cut to `maxResults`, guarantees kept.
    /// Every other `reason` is cleared; this function owns the field. The one
    /// exception is a cycle-the-whole-way option, whose reason ("Quiet
    /// roads") comes from the cycling provider and is kept as given.
    static func rank(_ itineraries: [Itinerary], context: RankingContext = RankingContext()) -> [Itinerary] {
        // Decorate with the index so the sort is stable; `sorted` is not
        // guaranteed to be.
        typealias Entry = (offset: Int, itinerary: Itinerary)
        let indexed: [Entry] = itineraries.enumerated().map { (offset: $0.offset, itinerary: $0.element) }
        let byCost: (Entry, Entry) -> Bool = { lhs, rhs in
            let lc = cost(lhs.itinerary, context: context), rc = cost(rhs.itinerary, context: context)
            if lc != rc { return lc < rc }
            return byDuration(lhs, rhs)
        }

        let pinned = indexed.filter { isPinnedRail($0.itinerary, context: context) }.sorted(by: byCost)
        let pinnedIds = Set(pinned.map(\.itinerary.id))
        let rest = indexed.filter { !pinnedIds.contains($0.itinerary.id) }.sorted(by: byCost)
        let ordered = pinned + rest

        // The fastest option per enabled mode, by duration alone.
        var fastestFor: [String: [TransitMode]] = [:]
        for mode in guaranteedModes where context.enabledModes.contains(mode) {
            guard let best = indexed.filter({ rides($0.itinerary, mode) }).min(by: byDuration) else { continue }
            fastestFor[best.itinerary.id, default: []].append(mode)
        }

        var result: [Itinerary] = ordered.enumerated().map { position, entry in
            var itinerary = entry.itinerary
            itinerary.reason = reason(for: itinerary, position: position, pinned: pinnedIds.contains(itinerary.id),
                                      fastestFor: fastestFor[itinerary.id])
            return itinerary
        }
        if result.count > maxResults {
            // Guarantees stay wherever they ranked; the rest fill up to the cap.
            var room = maxResults - result.filter { fastestFor[$0.id] != nil }.count
            result = result.filter { itinerary in
                if fastestFor[itinerary.id] != nil { return true }
                guard room > 0 else { return false }
                room -= 1
                return true
            }
        }
        return result
    }

    /// The chip for one row. The rail pin says "Rail"; a cycle keeps the
    /// cycling provider's words when it has any; a per-mode fastest option
    /// below the first row says "Fastest by <mode>"; anything else, nothing.
    private static func reason(for itinerary: Itinerary, position: Int, pinned: Bool,
                               fastestFor modes: [TransitMode]?) -> String? {
        if pinned { return railReason }
        if isBikeOnly(itinerary), let given = itinerary.reason, !given.isEmpty { return given }
        guard position > 0, let modes, let named = chipMode(for: itinerary, among: modes) else { return nil }
        return fastestReason(named)
    }

    /// Duration plus double the walking beyond the user's limit.
    static func cost(_ itinerary: Itinerary, context: RankingContext) -> Int {
        guard let limit = context.walkToleranceSeconds else { return itinerary.durationSeconds }
        return itinerary.durationSeconds + 2 * max(0, itinerary.walkSeconds - limit)
    }

    private static func byDuration(_ lhs: (offset: Int, itinerary: Itinerary),
                                   _ rhs: (offset: Int, itinerary: Itinerary)) -> Bool {
        if lhs.itinerary.durationSeconds != rhs.itinerary.durationSeconds {
            return lhs.itinerary.durationSeconds < rhs.itinerary.durationSeconds
        }
        if lhs.itinerary.start != rhs.itinerary.start {
            return lhs.itinerary.start < rhs.itinerary.start
        }
        return lhs.offset < rhs.offset
    }

    /// Any leg of `mode`.
    static func rides(_ itinerary: Itinerary, _ mode: TransitMode) -> Bool {
        itinerary.legs.contains { $0.mode == mode }
    }

    /// When one option is the fastest on several networks, the chip names
    /// the one it rides longest; ties go in `guaranteedModes` order.
    static func chipMode(for itinerary: Itinerary, among modes: [TransitMode]) -> TransitMode? {
        modes.max { lhs, rhs in
            let l = ridingSeconds(itinerary, lhs), r = ridingSeconds(itinerary, rhs)
            if l != r { return l < r }
            // `max` keeps the later element on a tie; reverse that so the
            // earlier in `guaranteedModes` wins.
            return guaranteedModes.firstIndex(of: lhs)! > guaranteedModes.firstIndex(of: rhs)!
        }
    }

    private static func ridingSeconds(_ itinerary: Itinerary, _ mode: TransitMode) -> Int {
        itinerary.legs.filter { $0.mode == mode }.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Every leg is a cycle: the direct bike option.
    static func isBikeOnly(_ itinerary: Itinerary) -> Bool {
        !itinerary.legs.isEmpty && itinerary.legs.allSatisfy { $0.mode == .bike }
    }

    /// Rides only Luas/DART/Rail, with the walks at either end inside the
    /// user's ceiling.
    static func isPinnedRail(_ itinerary: Itinerary, context: RankingContext) -> Bool {
        guard context.preferRail else { return false }
        let transit = itinerary.transitLegs
        guard !transit.isEmpty, transit.allSatisfy({ railModes.contains($0.mode) }) else { return false }
        return itinerary.firstAndLastWalkSeconds <= context.railWalkCeilingSeconds
    }
}
