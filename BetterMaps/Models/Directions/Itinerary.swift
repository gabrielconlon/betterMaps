import Foundation

/// One complete door-to-door option returned by a `JourneyProvider`.
/// Identity is `id` alone (see `Leg`).
struct Itinerary: Identifiable, Hashable, Sendable {
    let id: String
    let legs: [Leg]
    let start: Date
    let end: Date
    let durationSeconds: Int
    let transfers: Int
    let walkSeconds: Int
    let bikeSeconds: Int
    /// Short label explaining why ranking put this option where it is
    /// ("Fewest changes"); nil when there is nothing to say.
    var reason: String?

    init(id: String, legs: [Leg], start: Date, end: Date, durationSeconds: Int,
         transfers: Int, walkSeconds: Int, bikeSeconds: Int, reason: String? = nil) {
        self.id = id
        self.legs = legs
        self.start = start
        self.end = end
        self.durationSeconds = durationSeconds
        self.transfers = transfers
        self.walkSeconds = walkSeconds
        self.bikeSeconds = bikeSeconds
        self.reason = reason
    }

    /// Legs that board a vehicle, in order.
    var transitLegs: [Leg] { legs.filter { $0.mode.isTransit } }

    /// Modes in leg order with consecutive repeats collapsed
    /// (walk, bus, bus, walk -> walk, bus, walk).
    var modes: [TransitMode] {
        var result: [TransitMode] = []
        for leg in legs where result.last != leg.mode {
            result.append(leg.mode)
        }
        return result
    }

    /// Walking at either end of the journey: the first leg if it is a walk
    /// plus the last leg if it is a walk. A single walk-only leg counts once.
    var firstAndLastWalkSeconds: Int {
        guard let first = legs.first else { return 0 }
        var total = first.mode == .walk ? first.durationSeconds : 0
        if legs.count > 1, let last = legs.last, last.mode == .walk {
            total += last.durationSeconds
        }
        return total
    }

    static func == (lhs: Itinerary, rhs: Itinerary) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
