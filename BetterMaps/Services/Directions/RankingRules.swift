import Foundation

/// Inputs that shape the order of itineraries beyond raw duration.
struct RankingContext: Sendable {
    var preferRail: Bool = false
    /// Walking at the two ends a rail option may total and still be pinned
    /// first.
    var railWalkCeilingSeconds: Int = 1200
    /// Ids of the itineraries the main query returned, as opposed to the
    /// probes' extras (rail-only, longer walk), so ranking can tell them apart.
    var baseIds: Set<String> = []
    /// Fewest vehicles boarded by any main-query itinerary; a probe extra
    /// that beats it earns "Fewer changes". Nil when there is nothing to
    /// compare against.
    var baseMinTransitLegs: Int? = nil

    init(preferRail: Bool = false, railWalkCeilingSeconds: Int = 1200, baseIds: Set<String> = [],
         baseMinTransitLegs: Int? = nil) {
        self.preferRail = preferRail
        self.railWalkCeilingSeconds = railWalkCeilingSeconds
        self.baseIds = baseIds
        self.baseMinTransitLegs = baseMinTransitLegs
    }
}

/// Orders a provider's itineraries for the directions sheet.
enum RankingRules {
    static let railReason = "Rail"
    static let fewerChangesReason = "Fewer changes"

    /// Networks that count as "rail" for the pin: trams included, since Luas
    /// is how most people reach a DART station from the city centre.
    static let railModes: Set<TransitMode> = [.luas, .dart, .rail]

    /// Pure and deterministic:
    /// 1. With `preferRail`, options that ride only rail modes and whose
    ///    walking at the two ends stays within the ceiling come first, by
    ///    duration, tagged "Rail".
    /// 2. Everything else follows by duration, then start time, then input
    ///    order. A probe extra (not in `baseIds`) that boards fewer vehicles
    ///    than any main-query option is tagged "Fewer changes".
    /// Every other `reason` is cleared; this function owns the field.
    static func rank(_ itineraries: [Itinerary], context: RankingContext = RankingContext()) -> [Itinerary] {
        // Decorate with the index so the sort is stable; `sorted` is not
        // guaranteed to be.
        let indexed = itineraries.enumerated().map { (offset: $0.offset, itinerary: $0.element) }
        let byDuration: ((offset: Int, itinerary: Itinerary), (offset: Int, itinerary: Itinerary)) -> Bool = { lhs, rhs in
            if lhs.itinerary.durationSeconds != rhs.itinerary.durationSeconds {
                return lhs.itinerary.durationSeconds < rhs.itinerary.durationSeconds
            }
            if lhs.itinerary.start != rhs.itinerary.start {
                return lhs.itinerary.start < rhs.itinerary.start
            }
            return lhs.offset < rhs.offset
        }

        let pinned = indexed.filter { isPinnedRail($0.itinerary, context: context) }.sorted(by: byDuration)
        let pinnedIds = Set(pinned.map(\.itinerary.id))
        let rest = indexed.filter { !pinnedIds.contains($0.itinerary.id) }.sorted(by: byDuration)

        var result: [Itinerary] = []
        result.reserveCapacity(itineraries.count)
        for entry in pinned {
            var itinerary = entry.itinerary
            itinerary.reason = railReason
            result.append(itinerary)
        }
        for entry in rest {
            var itinerary = entry.itinerary
            itinerary.reason = hasFewerChanges(itinerary, context: context) ? fewerChangesReason : nil
            result.append(itinerary)
        }
        return result
    }

    /// Rides only Luas/DART/Rail, with the walks at either end inside the
    /// user's ceiling.
    static func isPinnedRail(_ itinerary: Itinerary, context: RankingContext) -> Bool {
        guard context.preferRail else { return false }
        let transit = itinerary.transitLegs
        guard !transit.isEmpty, transit.allSatisfy({ railModes.contains($0.mode) }) else { return false }
        return itinerary.firstAndLastWalkSeconds <= context.railWalkCeilingSeconds
    }

    /// A probe extra that boards fewer vehicles than any main-query option.
    /// Walk- or bike-only options never qualify: "fewer changes" means
    /// nothing when nothing is boarded.
    static func hasFewerChanges(_ itinerary: Itinerary, context: RankingContext) -> Bool {
        guard let baseMin = context.baseMinTransitLegs, !context.baseIds.contains(itinerary.id) else { return false }
        let boarded = itinerary.transitLegs.count
        return boarded > 0 && boarded < baseMin
    }
}
