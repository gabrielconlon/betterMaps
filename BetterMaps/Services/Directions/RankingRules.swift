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
    /// The plan is "arrive by" a time: the same ride on an earlier service
    /// only gets you there sooner and waiting, so the latest one wins.
    var arriveBy: Bool = false
    /// The time the user must arrive by, when `arriveBy` is on. With it, an
    /// option is costed from when it leaves rather than how long it rides
    /// (waiting at the far end is time the user has spent too), and options
    /// that get there hours early are dropped. Without the engine having a
    /// service near the target (DART on a Sunday morning) it searches back
    /// as far as it must, and "arrive by 09:15" came back topped by the last
    /// DART of the night before.
    var arriveByTime: Date? = nil

    init(preferRail: Bool = false, railWalkCeilingSeconds: Int = 1200,
         walkToleranceSeconds: Int? = nil, enabledModes: Set<TransitMode> = [],
         arriveBy: Bool = false, arriveByTime: Date? = nil) {
        self.preferRail = preferRail
        self.railWalkCeilingSeconds = railWalkCeilingSeconds
        self.walkToleranceSeconds = walkToleranceSeconds
        self.enabledModes = enabledModes
        self.arriveBy = arriveBy
        self.arriveByTime = arriveByTime
    }

    /// The arrive-by target when ranking is arriving by a time.
    var arrivalTarget: Date? { arriveBy ? arriveByTime : nil }
}

/// What ranking produced: the list in order, and which rows are there by
/// guarantee (the first row, the rail pin, the fastest per enabled mode)
/// rather than by score alone. The map previews those rows before one is
/// picked, so the set is stated here instead of being read back out of
/// each row's `reason` text.
struct RankedItineraries: Equatable, Sendable {
    var itineraries: [Itinerary]
    var guaranteedIds: Set<Itinerary.ID>

    init(itineraries: [Itinerary] = [], guaranteedIds: Set<Itinerary.ID> = []) {
        self.itineraries = itineraries
        self.guaranteedIds = guaranteedIds
    }

    /// The guaranteed rows, in list order.
    var guaranteed: [Itinerary] {
        itineraries.filter { guaranteedIds.contains($0.id) }
    }
}

/// Orders a provider's itineraries for the directions sheet.
enum RankingRules {
    static let railReason = "Rail"
    static let fastestByPrefix = "Fastest by "
    /// The most options the sheet lists.
    static let maxResults = 8
    /// Arriving by a time, an option that gets there more than this long
    /// before it is not one anyone would take; it is left out.
    static let maxArriveByEarlySeconds = 4 * 3600

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
    /// 0. Arriving by a time, options that take the same rides (same
    ///    networks, routes and stops) on different services collapse to the
    ///    one arriving latest, and equal costs go to the later arrival. The
    ///    engine answers an arrive-by query with a run of departures of one
    ///    train (8:13, 8:29, 8:41, 8:59, 9:14 for a 9:15 arrival); only the
    ///    last one is worth listing. Options arriving more than
    ///    `maxArriveByEarlySeconds` before the target are dropped.
    /// 1. Each option's cost is its duration (arriving by a known time: the
    ///    time from leaving to the target, so waiting counts) plus double whatever walking
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
    /// `guaranteedIds` names the first row, the rail pins and the fastest per
    /// mode (the bike included, whatever its reason says).
    static func rank(_ itineraries: [Itinerary], context: RankingContext = RankingContext()) -> RankedItineraries {
        // Decorate with the index so the sort is stable (`sorted` is not
        // guaranteed to be) and with the cost, worked out once per option.
        let input = context.arriveBy ? latestPerRide(withinArriveByWindow(itineraries, context: context)) : itineraries
        let indexed: [Entry] = input.enumerated().map {
            Entry(offset: $0.offset, itinerary: $0.element, cost: cost($0.element, context: context))
        }
        let byCost: (Entry, Entry) -> Bool = { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            if context.arriveBy, lhs.itinerary.durationSeconds == rhs.itinerary.durationSeconds,
               lhs.itinerary.end != rhs.itinerary.end {
                return lhs.itinerary.end > rhs.itinerary.end
            }
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
        var guaranteed = Set(result.map(\.id)).filter { pinnedIds.contains($0) || fastestFor[$0] != nil }
        if let first = result.first { guaranteed.insert(first.id) }
        return RankedItineraries(itineraries: result, guaranteedIds: guaranteed)
    }

    /// Keeps, for each distinct ride (`rideKey`), the option arriving
    /// latest, ties to the later departure, in input order otherwise. Walk-
    /// and bike-only options have no ride and pass through.
    static func latestPerRide(_ itineraries: [Itinerary]) -> [Itinerary] {
        var best: [String: Itinerary] = [:]
        for itinerary in itineraries {
            guard let key = rideKey(itinerary) else { continue }
            if let kept = best[key],
               (kept.end, kept.start) >= (itinerary.end, itinerary.start) { continue }
            best[key] = itinerary
        }
        return itineraries.filter { itinerary in
            guard let key = rideKey(itinerary) else { return true }
            return best[key]?.id == itinerary.id
        }
    }

    /// Drops options that arrive more than `maxArriveByEarlySeconds` before
    /// the arrive-by target. Everything passes when there is no target.
    static func withinArriveByWindow(_ itineraries: [Itinerary], context: RankingContext) -> [Itinerary] {
        guard let target = context.arrivalTarget else { return itineraries }
        let earliest = target.addingTimeInterval(-TimeInterval(maxArriveByEarlySeconds))
        return itineraries.filter { $0.end >= earliest }
    }

    /// The transit legs' network, route and stops, in order; nil when there
    /// is no transit leg.
    static func rideKey(_ itinerary: Itinerary) -> String? {
        let transit = itinerary.transitLegs
        guard !transit.isEmpty else { return nil }
        return transit.map {
            [$0.mode.rawValue, $0.routeShortName ?? "", $0.fromStopId ?? $0.fromName,
             $0.toStopId ?? $0.toName].joined(separator: "|")
        }.joined(separator: ">")
    }

    /// One input option with its place in the input and its cost.
    private struct Entry {
        let offset: Int
        let itinerary: Itinerary
        let cost: Int
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

    /// Duration plus double the walking beyond the user's limit. Arriving
    /// by a known time, the duration is counted from leaving to the target,
    /// so a ride that gets there early pays for the wait.
    static func cost(_ itinerary: Itinerary, context: RankingContext) -> Int {
        var base = itinerary.durationSeconds
        if let target = context.arrivalTarget {
            base = max(base, Int(target.timeIntervalSince(itinerary.start).rounded()))
        }
        guard let limit = context.walkToleranceSeconds else { return base }
        return base + 2 * max(0, itinerary.walkSeconds - limit)
    }

    private static func byDuration(_ lhs: Entry, _ rhs: Entry) -> Bool {
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
