import XCTest
@testable import CustomMapApp

/// Ranking is a stable sort by duration then start, with a rail pin in
/// front when asked for; `reason` is owned by the ranker.
final class RankingRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func itinerary(_ id: String, duration: Int, startOffset: TimeInterval = 0,
                           reason: String? = nil) -> Itinerary {
        let start = t0.addingTimeInterval(startOffset)
        let leg = Leg(id: "\(id)-walk", mode: .walk, fromName: "A", toName: "B",
                      start: start, end: start.addingTimeInterval(TimeInterval(duration)),
                      durationSeconds: duration)
        return Itinerary(id: id, legs: [leg], start: start,
                         end: start.addingTimeInterval(TimeInterval(duration)),
                         durationSeconds: duration, transfers: 0, walkSeconds: duration,
                         bikeSeconds: 0, reason: reason)
    }

    /// Walk › ride… › walk, each leg given as (mode, minutes).
    private func journey(_ id: String, _ legs: [(TransitMode, Int)], startOffset: TimeInterval = 0) -> Itinerary {
        var cursor = t0.addingTimeInterval(startOffset)
        var built: [Leg] = []
        for (index, (mode, minutes)) in legs.enumerated() {
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            built.append(Leg(id: "\(id)-\(index)", mode: mode, routeShortName: mode.isTransit ? "X" : nil,
                             fromName: "A", toName: "B", start: cursor, end: end, durationSeconds: minutes * 60))
            cursor = end
        }
        let start = t0.addingTimeInterval(startOffset)
        let transit = built.filter { $0.mode.isTransit }.count
        return Itinerary(id: id, legs: built, start: start, end: cursor,
                         durationSeconds: Int(cursor.timeIntervalSince(start)),
                         transfers: max(transit - 1, 0),
                         walkSeconds: built.filter { $0.mode == .walk }.reduce(0) { $0 + $1.durationSeconds },
                         bikeSeconds: 0)
    }

    /// Heuston → Dún Laoghaire-style set: a quick bus, a Luas+DART option
    /// with 2 + 2 minutes of walking, a slower bus with a change.
    private var heustonSet: [Itinerary] {
        [
            journey("bus", [(.walk, 4), (.bus, 51), (.walk, 2)]),
            journey("rail", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 26), (.walk, 2)], startOffset: 60),
            journey("bus2", [(.walk, 3), (.bus, 20), (.walk, 1), (.bus, 40), (.walk, 1)], startOffset: 120),
        ]
    }

    private func context(preferRail: Bool = true, ceilingMinutes: Int = 20, baseIds: Set<String> = [],
                         baseMin: Int? = nil) -> RankingContext {
        RankingContext(preferRail: preferRail, railWalkCeilingSeconds: ceilingMinutes * 60,
                       baseIds: baseIds, baseMinTransitLegs: baseMin)
    }

    // MARK: Rail pin

    func testRailOptionWithinWalkCeilingIsPinnedFirst() {
        let ranked = RankingRules.rank(heustonSet, context: context(ceilingMinutes: 20))
        XCTAssertEqual(ranked.map(\.id), ["rail", "bus", "bus2"])
        XCTAssertEqual(ranked.map(\.reason), ["Rail", nil, nil])
        XCTAssertEqual(ranked[0].firstAndLastWalkSeconds, 4 * 60, "the middle walk does not count")
    }

    func testRailOptionOverWalkCeilingIsNotPinned() {
        let ranked = RankingRules.rank(heustonSet, context: context(ceilingMinutes: 2))
        XCTAssertEqual(ranked.map(\.id), ["rail", "bus", "bus2"], "still fastest, so still first")
        XCTAssertEqual(ranked.map(\.reason), [nil, nil, nil], "but not for being rail")

        let slowRail = heustonSet.map { $0.id == "rail" ? journey("rail", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 40), (.walk, 2)]) : $0 }
        XCTAssertEqual(RankingRules.rank(slowRail, context: context(ceilingMinutes: 2)).map(\.id), ["bus", "rail", "bus2"])
        XCTAssertEqual(RankingRules.rank(slowRail, context: context(ceilingMinutes: 20)).map(\.id), ["rail", "bus", "bus2"],
                       "pinned ahead of a faster bus when within the ceiling")
    }

    func testPreferRailOffNeverPins() {
        let slowRail = heustonSet.map { $0.id == "rail" ? journey("rail", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 40), (.walk, 2)]) : $0 }
        let ranked = RankingRules.rank(slowRail, context: context(preferRail: false))
        XCTAssertEqual(ranked.map(\.id), ["bus", "rail", "bus2"])
        XCTAssertEqual(ranked.compactMap(\.reason), [])
    }

    func testBusOnlySetHasNoRailReason() {
        let buses = heustonSet.filter { $0.id != "rail" }
        let ranked = RankingRules.rank(buses, context: context())
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.compactMap(\.reason), [])
    }

    func testMixedRailAndBusIsNotRail() {
        let mixed = [journey("mixed", [(.walk, 2), (.dart, 20), (.walk, 2), (.bus, 10), (.walk, 1)])]
        XCTAssertEqual(RankingRules.rank(mixed, context: context()).first?.reason, nil)
        let walkOnly = [itinerary("walk", duration: 600)]
        XCTAssertEqual(RankingRules.rank(walkOnly, context: context()).first?.reason, nil)
    }

    func testPinnedRailOptionsAreOrderedByDurationAmongThemselves() {
        let set = [
            journey("rail-slow", [(.walk, 2), (.dart, 40), (.walk, 2)]),
            journey("bus", [(.walk, 4), (.bus, 20), (.walk, 2)]),
            journey("rail-fast", [(.walk, 2), (.dart, 30), (.walk, 2)]),
        ]
        XCTAssertEqual(RankingRules.rank(set, context: context()).map(\.id), ["rail-fast", "rail-slow", "bus"])
    }

    // MARK: Fewer changes

    func testProbeExtraWithFewerBoardingsIsTagged() {
        let base = [
            journey("b1", [(.walk, 3), (.bus, 20), (.walk, 1), (.bus, 20), (.walk, 1)]),
            journey("b2", [(.walk, 3), (.bus, 25), (.walk, 1), (.luas, 20), (.walk, 1)]),
        ]
        let probe = journey("p1", [(.walk, 12), (.bus, 40), (.walk, 8)])
        let ranked = RankingRules.rank(base + [probe],
                                       context: context(preferRail: false, baseIds: ["b1", "b2"], baseMin: 2))
        XCTAssertEqual(ranked.first { $0.id == "p1" }?.reason, "Fewer changes")
        XCTAssertEqual(ranked.filter { $0.id != "p1" }.compactMap(\.reason), [])
    }

    func testBaseItinerariesAndEqualBoardingsAreNotTagged() {
        let base = journey("b1", [(.walk, 3), (.bus, 40), (.walk, 1)])
        let sameChanges = journey("p1", [(.walk, 12), (.bus, 40), (.walk, 8)])
        let walkOnly = itinerary("p2", duration: 3600)
        let ranked = RankingRules.rank([base, sameChanges, walkOnly],
                                       context: context(preferRail: false, baseIds: ["b1"], baseMin: 1))
        XCTAssertEqual(ranked.compactMap(\.reason), [], "1 is not fewer than 1; a walk boards nothing")

        let noBaseMin = RankingRules.rank([base, sameChanges], context: context(preferRail: false, baseIds: ["b1"]))
        XCTAssertEqual(noBaseMin.compactMap(\.reason), [])
    }

    func testRailPinWinsOverFewerChanges() {
        let base = journey("b1", [(.walk, 3), (.bus, 20), (.walk, 1), (.bus, 20), (.walk, 1)])
        let probe = journey("rail", [(.walk, 2), (.dart, 50), (.walk, 2)])
        let ranked = RankingRules.rank([base, probe], context: context(baseIds: ["b1"], baseMin: 2))
        XCTAssertEqual(ranked.map(\.id), ["rail", "b1"])
        XCTAssertEqual(ranked.first?.reason, "Rail")
    }

    // MARK: Determinism

    func testTiesAreDeterministicAcrossRuns() {
        let set = [
            journey("rail-a", [(.walk, 2), (.dart, 30), (.walk, 2)]),
            journey("rail-b", [(.walk, 2), (.dart, 30), (.walk, 2)]),
            journey("bus-a", [(.walk, 4), (.bus, 30), (.walk, 0)]),
            journey("bus-b", [(.walk, 4), (.bus, 30), (.walk, 0)]),
        ]
        let first = RankingRules.rank(set, context: context(baseIds: ["rail-a", "bus-a"], baseMin: 1))
        for _ in 0..<20 {
            XCTAssertEqual(RankingRules.rank(set, context: context(baseIds: ["rail-a", "bus-a"], baseMin: 1)), first)
        }
        XCTAssertEqual(first.map(\.id), ["rail-a", "rail-b", "bus-a", "bus-b"], "ties keep input order")
    }

    func testSortsByDuration() {
        let input = [itinerary("slow", duration: 1800), itinerary("fast", duration: 600),
                     itinerary("mid", duration: 1200)]
        XCTAssertEqual(RankingRules.rank(input).map(\.id), ["fast", "mid", "slow"])
    }

    func testEqualDurationsKeepInputOrder() {
        let input = [itinerary("c", duration: 900), itinerary("a", duration: 900),
                     itinerary("b", duration: 900), itinerary("z", duration: 300)]
        XCTAssertEqual(RankingRules.rank(input).map(\.id), ["z", "c", "a", "b"])
    }

    func testEqualDurationsBreakTiesOnStartBeforeInputOrder() {
        let input = [itinerary("later", duration: 900, startOffset: 600),
                     itinerary("earlier", duration: 900, startOffset: 0)]
        XCTAssertEqual(RankingRules.rank(input).map(\.id), ["earlier", "later"])
    }

    func testStaleReasonsAreCleared() {
        // A provider may have ranked already; the view model's pass decides.
        let input = [itinerary("a", duration: 1200, reason: "Rail"),
                     itinerary("b", duration: 600, reason: "Fewer changes")]
        let ranked = RankingRules.rank(input)
        XCTAssertEqual(ranked.map(\.reason), [nil, nil])
    }

    func testBikeOnlyReasonIsPreserved() {
        // The cycling provider names the style ("Quiet roads"); ranking does
        // not own that reason and leaves it as it found it.
        let bikeStart = t0
        let bikeLeg = Leg(id: "bike-leg", mode: .bike, fromName: "Start", toName: "Destination",
                          start: bikeStart, end: bikeStart.addingTimeInterval(1500), durationSeconds: 1500)
        let bike = Itinerary(id: "bike", legs: [bikeLeg], start: bikeStart, end: bikeStart.addingTimeInterval(1500),
                             durationSeconds: 1500, transfers: 0, walkSeconds: 0, bikeSeconds: 1500, reason: "Quiet roads")
        let ranked = RankingRules.rank(heustonSet + [bike], context: context(baseIds: ["bus", "rail", "bus2"], baseMin: 1))
        XCTAssertEqual(ranked.map(\.id), ["rail", "bike", "bus", "bus2"], "pinned rail, then by duration")
        XCTAssertEqual(ranked.first { $0.id == "bike" }?.reason, "Quiet roads")
        XCTAssertTrue(RankingRules.isBikeOnly(bike))
        XCTAssertFalse(RankingRules.isBikeOnly(heustonSet[0]))

        var plainBike = bike
        plainBike.reason = nil
        XCTAssertNil(RankingRules.rank([plainBike], context: context()).first?.reason, "nothing is invented either")
    }

    func testEmptyInputGivesEmptyOutput() {
        XCTAssertTrue(RankingRules.rank([]).isEmpty)
    }
}
