import Foundation

/// Inputs that shape the order of itineraries beyond raw duration.
struct RankingContext: Sendable {
    var preferRail: Bool = false
    /// Extra walking a rail option may add and still be pinned first.
    var railWalkCeilingSeconds: Int = 1200
    /// Ids of the itineraries the provider returned before any local
    /// additions (a direct bike leg, say), so ranking can tell them apart.
    var baseIds: Set<String> = []

    init(preferRail: Bool = false, railWalkCeilingSeconds: Int = 1200, baseIds: Set<String> = []) {
        self.preferRail = preferRail
        self.railWalkCeilingSeconds = railWalkCeilingSeconds
        self.baseIds = baseIds
    }
}

/// Orders a provider's itineraries for the directions sheet.
enum RankingRules {
    /// Phase 0: stable sort by duration, then start time. Ties keep the
    /// provider's order and `reason` is passed through untouched.
    static func rank(_ itineraries: [Itinerary], context: RankingContext = RankingContext()) -> [Itinerary] {
        // Decorate with the index so the sort is stable; `sorted` is not
        // guaranteed to be.
        let indexed = itineraries.enumerated().map { (offset: $0.offset, itinerary: $0.element) }
        let ordered = indexed.sorted { lhs, rhs in
            if lhs.itinerary.durationSeconds != rhs.itinerary.durationSeconds {
                return lhs.itinerary.durationSeconds < rhs.itinerary.durationSeconds
            }
            if lhs.itinerary.start != rhs.itinerary.start {
                return lhs.itinerary.start < rhs.itinerary.start
            }
            return lhs.offset < rhs.offset
        }
        // Phase 2: rail pin and fewer-changes reasons
        return ordered.map(\.itinerary)
    }
}
