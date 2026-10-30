import XCTest
@testable import CustomMapApp

/// Ranking is a stable sort by cost (duration plus double the walking past
/// the user's limit), then duration, then start, with a rail pin in front
/// when asked for and the fastest option per enabled mode always kept;
/// `reason` is owned by the ranker.
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

    private func context(preferRail: Bool = true, ceilingMinutes: Int = 20, walkMinutes: Int? = nil,
                         enabled: Set<TransitMode> = []) -> RankingContext {
        RankingContext(preferRail: preferRail, railWalkCeilingSeconds: ceilingMinutes * 60,
                       walkToleranceSeconds: walkMinutes.map { $0 * 60 }, enabledModes: enabled)
    }

    // MARK: Rail pin

    func testRailOptionWithinWalkCeilingIsPinnedFirst() {
        let ranked = RankingRules.rank(heustonSet, context: context(ceilingMinutes: 20)).itineraries
        XCTAssertEqual(ranked.map(\.id), ["rail", "bus", "bus2"])
        XCTAssertEqual(ranked.map(\.reason), ["Rail", nil, nil])
        XCTAssertEqual(ranked[0].firstAndLastWalkSeconds, 4 * 60, "the middle walk does not count")
    }

    func testRailOptionOverWalkCeilingIsNotPinned() {
        let ranked = RankingRules.rank(heustonSet, context: context(ceilingMinutes: 2)).itineraries
        XCTAssertEqual(ranked.map(\.id), ["rail", "bus", "bus2"], "still fastest, so still first")
        XCTAssertEqual(ranked.map(\.reason), [nil, nil, nil], "but not for being rail")

        let slowRail = heustonSet.map { $0.id == "rail" ? journey("rail", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 40), (.walk, 2)]) : $0 }
        XCTAssertEqual(RankingRules.rank(slowRail, context: context(ceilingMinutes: 2)).itineraries.map(\.id), ["bus", "rail", "bus2"])
        XCTAssertEqual(RankingRules.rank(slowRail, context: context(ceilingMinutes: 20)).itineraries.map(\.id), ["rail", "bus", "bus2"],
                       "pinned ahead of a faster bus when within the ceiling")
    }

    func testPreferRailOffNeverPins() {
        let slowRail = heustonSet.map { $0.id == "rail" ? journey("rail", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 40), (.walk, 2)]) : $0 }
        let ranked = RankingRules.rank(slowRail, context: context(preferRail: false)).itineraries
        XCTAssertEqual(ranked.map(\.id), ["bus", "rail", "bus2"])
        XCTAssertEqual(ranked.compactMap(\.reason), [])
    }

    func testBusOnlySetHasNoRailReason() {
        let buses = heustonSet.filter { $0.id != "rail" }
        let ranked = RankingRules.rank(buses, context: context()).itineraries
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.compactMap(\.reason), [])
    }

    func testMixedRailAndBusIsNotRail() {
        let mixed = [journey("mixed", [(.walk, 2), (.dart, 20), (.walk, 2), (.bus, 10), (.walk, 1)])]
        XCTAssertEqual(RankingRules.rank(mixed, context: context()).itineraries.first?.reason, nil)
        let walkOnly = [itinerary("walk", duration: 600)]
        XCTAssertEqual(RankingRules.rank(walkOnly, context: context()).itineraries.first?.reason, nil)
    }

    func testPinnedRailOptionsAreOrderedByDurationAmongThemselves() {
        let set = [
            journey("rail-slow", [(.walk, 2), (.dart, 40), (.walk, 2)]),
            journey("bus", [(.walk, 4), (.bus, 20), (.walk, 2)]),
            journey("rail-fast", [(.walk, 2), (.dart, 30), (.walk, 2)]),
        ]
        XCTAssertEqual(RankingRules.rank(set, context: context()).itineraries.map(\.id), ["rail-fast", "rail-slow", "bus"])
    }

    // MARK: Walk limit as cost

    func testNoWalkLimitSortsByDurationAlone() {
        let set = [
            journey("long-walk", [(.walk, 20), (.bus, 10), (.walk, 10)]),
            journey("short-walk", [(.walk, 2), (.bus, 40), (.walk, 2)]),
        ]
        let ranked = RankingRules.rank(set, context: context(preferRail: false, walkMinutes: nil)).itineraries
        XCTAssertEqual(ranked.map(\.id), ["long-walk", "short-walk"], "40 min beats 44 min when any walk is fine")
        XCTAssertEqual(RankingRules.cost(set[0], context: context(walkMinutes: nil)), 40 * 60)
    }

    func testWalkingPastTheLimitCostsDouble() {
        let set = [
            journey("long-walk", [(.walk, 20), (.bus, 10), (.walk, 10)]),   // 40 min, 30 min walking
            journey("short-walk", [(.walk, 2), (.bus, 40), (.walk, 2)]),    // 44 min, 4 min walking
        ]
        let ctx = context(preferRail: false, walkMinutes: 10)
        XCTAssertEqual(RankingRules.cost(set[0], context: ctx), (40 + 2 * 20) * 60)
        XCTAssertEqual(RankingRules.cost(set[1], context: ctx), 44 * 60, "walking within the limit is free")
        XCTAssertEqual(RankingRules.rank(set, context: ctx).itineraries.map(\.id), ["short-walk", "long-walk"])
        XCTAssertEqual(RankingRules.rank(set, context: context(preferRail: false, walkMinutes: 30)).itineraries.map(\.id),
                       ["long-walk", "short-walk"], "a 30-minute limit makes the walk free again")
    }

    // MARK: Fastest per mode

    func testFastestPerEnabledModeIsKeptAndTaggedEvenWhenItsCostIsWorst() {
        var set = (0..<9).map { journey("bus\($0)", [(.walk, 2), (.bus, 30 + $0), (.walk, 2)]) }
        set.append(journey("dart", [(.walk, 30), (.dart, 20), (.walk, 25)]))   // 75 min, 55 min walking
        let ranked = RankingRules.rank(set, context: context(preferRail: false, walkMinutes: 5, enabled: [.bus, .dart])).itineraries
        XCTAssertEqual(ranked.count, RankingRules.maxResults)
        XCTAssertEqual(ranked.last?.id, "dart", "ranked last, but kept")
        XCTAssertEqual(ranked.last?.reason, "Fastest by DART")
        XCTAssertEqual(ranked.map(\.id).prefix(7), ["bus0", "bus1", "bus2", "bus3", "bus4", "bus5", "bus6"])
        XCTAssertFalse(ranked.contains { $0.id == "bus7" || $0.id == "bus8" }, "the worst unguaranteed rows go")
    }

    func testFirstRowCarriesNoChip() {
        let ranked = RankingRules.rank(heustonSet, context: context(preferRail: false, enabled: [.bus, .luas, .dart])).itineraries
        XCTAssertEqual(ranked.map(\.id), ["rail", "bus", "bus2"])
        XCTAssertNil(ranked[0].reason, "the fastest Luas and DART option is first: nothing to explain")
        XCTAssertEqual(ranked[1].reason, "Fastest by Bus")
        XCTAssertNil(ranked[2].reason)
    }

    func testRailPinOutranksFastestByChip() {
        let slowRail = heustonSet.map { $0.id == "rail" ? journey("rail", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 40), (.walk, 2)]) : $0 }
        let ranked = RankingRules.rank(slowRail, context: context(enabled: [.bus, .luas, .dart])).itineraries
        XCTAssertEqual(ranked.map(\.id), ["rail", "bus", "bus2"])
        XCTAssertEqual(ranked[0].reason, "Rail", "pinned, so not 'Fastest by DART'")
        XCTAssertEqual(ranked[1].reason, "Fastest by Bus")
    }

    func testOneChipPerRowNamesTheLongestRide() {
        let set = [
            journey("bus", [(.walk, 2), (.bus, 20), (.walk, 2)]),
            journey("luas-dart", [(.walk, 2), (.luas, 13), (.walk, 3), (.dart, 26), (.walk, 2)]),
            journey("dart-luas", [(.walk, 2), (.dart, 10), (.walk, 3), (.luas, 40), (.walk, 2)]),
        ]
        let ranked = RankingRules.rank(set, context: context(preferRail: false, enabled: [.bus, .luas, .dart])).itineraries
        XCTAssertEqual(ranked.map(\.id), ["bus", "luas-dart", "dart-luas"])
        XCTAssertEqual(ranked[1].reason, "Fastest by DART", "fastest on both networks; it rides DART longer")
        XCTAssertNil(ranked[2].reason)
        XCTAssertEqual(RankingRules.chipMode(for: set[2], among: [.luas, .dart]), .luas)
        XCTAssertEqual(RankingRules.chipMode(for: set[0], among: [.bus]), .bus)
    }

    func testDisabledModesEarnNoChip() {
        let ranked = RankingRules.rank(heustonSet, context: context(preferRail: false, enabled: [.luas])).itineraries
        XCTAssertEqual(ranked.compactMap(\.reason), [], "the Luas option is first; the buses are not enabled modes")
        XCTAssertEqual(RankingRules.rank(heustonSet, context: context(preferRail: false)).itineraries.compactMap(\.reason), [])
    }

    func testListIsCappedAtEight() {
        let set = (0..<12).map { journey("bus\($0)", [(.walk, 2), (.bus, 30 + $0), (.walk, 2)]) }
        let ranked = RankingRules.rank(set, context: context(preferRail: false, enabled: [.bus])).itineraries
        XCTAssertEqual(ranked.map(\.id), (0..<8).map { "bus\($0)" })
        XCTAssertEqual(ranked.compactMap(\.reason), [])
    }

    func testBikeGuaranteeFallsBackToFastestByBike() {
        let bikeStart = t0
        let bikeLeg = Leg(id: "bike-leg", mode: .bike, fromName: "Start", toName: "Destination",
                          start: bikeStart, end: bikeStart.addingTimeInterval(4200), durationSeconds: 4200)
        let bike = Itinerary(id: "bike", legs: [bikeLeg], start: bikeStart, end: bikeStart.addingTimeInterval(4200),
                             durationSeconds: 4200, transfers: 0, walkSeconds: 0, bikeSeconds: 4200)
        let ranked = RankingRules.rank(heustonSet + [bike], context: context(preferRail: false, enabled: [.bike])).itineraries
        XCTAssertEqual(ranked.last?.id, "bike")
        XCTAssertEqual(ranked.last?.reason, "Fastest by Bike")

        var quiet = bike
        quiet.reason = "Quiet roads"
        XCTAssertEqual(RankingRules.rank(heustonSet + [quiet], context: context(preferRail: false, enabled: [.bike])).itineraries.last?.reason,
                       "Quiet roads", "the cycling provider's words win")
    }

    // MARK: Determinism

    func testTiesAreDeterministicAcrossRuns() {
        let set = [
            journey("rail-a", [(.walk, 2), (.dart, 30), (.walk, 2)]),
            journey("rail-b", [(.walk, 2), (.dart, 30), (.walk, 2)]),
            journey("bus-a", [(.walk, 4), (.bus, 30), (.walk, 0)]),
            journey("bus-b", [(.walk, 4), (.bus, 30), (.walk, 0)]),
        ]
        let first = RankingRules.rank(set, context: context(walkMinutes: 10, enabled: [.bus, .dart])).itineraries
        for _ in 0..<20 {
            XCTAssertEqual(RankingRules.rank(set, context: context(walkMinutes: 10, enabled: [.bus, .dart])).itineraries, first)
        }
        XCTAssertEqual(first.map(\.id), ["rail-a", "rail-b", "bus-a", "bus-b"], "ties keep input order")
    }

    func testSortsByDuration() {
        let input = [itinerary("slow", duration: 1800), itinerary("fast", duration: 600),
                     itinerary("mid", duration: 1200)]
        XCTAssertEqual(RankingRules.rank(input).itineraries.map(\.id), ["fast", "mid", "slow"])
    }

    func testEqualDurationsKeepInputOrder() {
        let input = [itinerary("c", duration: 900), itinerary("a", duration: 900),
                     itinerary("b", duration: 900), itinerary("z", duration: 300)]
        XCTAssertEqual(RankingRules.rank(input).itineraries.map(\.id), ["z", "c", "a", "b"])
    }

    func testEqualDurationsBreakTiesOnStartBeforeInputOrder() {
        let input = [itinerary("later", duration: 900, startOffset: 600),
                     itinerary("earlier", duration: 900, startOffset: 0)]
        XCTAssertEqual(RankingRules.rank(input).itineraries.map(\.id), ["earlier", "later"])
    }

    func testStaleReasonsAreCleared() {
        // A provider may have ranked already; the view model's pass decides.
        let input = [itinerary("a", duration: 1200, reason: "Rail"),
                     itinerary("b", duration: 600, reason: "Fewer changes")]
        let ranked = RankingRules.rank(input).itineraries
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
        let ranked = RankingRules.rank(heustonSet + [bike], context: context(enabled: [.bus, .luas, .dart, .rail, .bike])).itineraries
        XCTAssertEqual(ranked.map(\.id), ["rail", "bike", "bus", "bus2"], "pinned rail, then by duration")
        XCTAssertEqual(ranked.first { $0.id == "bike" }?.reason, "Quiet roads")
        XCTAssertEqual(ranked.first { $0.id == "bus" }?.reason, "Fastest by Bus")
        XCTAssertTrue(RankingRules.isBikeOnly(bike))
        XCTAssertFalse(RankingRules.isBikeOnly(heustonSet[0]))

        var plainBike = bike
        plainBike.reason = nil
        XCTAssertNil(RankingRules.rank([plainBike], context: context()).itineraries.first?.reason, "nothing is invented either")
    }

    func testEmptyInputGivesEmptyOutput() {
        let ranked = RankingRules.rank([])
        XCTAssertTrue(ranked.itineraries.isEmpty)
        XCTAssertTrue(ranked.guaranteedIds.isEmpty)
    }

    // MARK: Guarantees

    func testGuaranteedIdsNameFirstRowRailPinAndFastestPerMode() {
        // Six buses, a slower DART, and a slow bike with the router's own
        // reason: the first row, the rail pin, the DART and the bike are
        // guaranteed; the other buses are there on score alone.
        let buses = (0..<6).map { journey("bus\($0)", [(.walk, 2), (.bus, 30 + $0), (.walk, 2)]) }
        let dart = journey("dart", [(.walk, 2), (.dart, 50), (.walk, 2)])
        let bikeLeg = Leg(id: "bike-leg", mode: .bike, fromName: "Start", toName: "Destination",
                          start: t0, end: t0.addingTimeInterval(4200), durationSeconds: 4200)
        let bike = Itinerary(id: "bike", legs: [bikeLeg], start: t0, end: t0.addingTimeInterval(4200),
                             durationSeconds: 4200, transfers: 0, walkSeconds: 0, bikeSeconds: 4200, reason: "Quiet roads")

        let ranked = RankingRules.rank(buses + [dart, bike], context: context(enabled: [.bus, .dart, .bike]))
        XCTAssertEqual(ranked.itineraries.map(\.id), ["dart", "bus0", "bus1", "bus2", "bus3", "bus4", "bus5", "bike"])
        XCTAssertEqual(ranked.guaranteedIds, ["dart", "bus0", "bike"])
        XCTAssertEqual(ranked.guaranteed.map(\.id), ["dart", "bus0", "bike"], "in list order")
        XCTAssertEqual(ranked.itineraries.last?.reason, "Quiet roads", "the guarantee does not depend on the chip text")

        let unpinned = RankingRules.rank(buses + [dart, bike], context: context(preferRail: false, enabled: [.bus, .dart, .bike]))
        XCTAssertEqual(unpinned.itineraries.first?.id, "bus0")
        XCTAssertEqual(unpinned.guaranteedIds, ["bus0", "dart", "bike"], "the first row is guaranteed whatever it is")

        let nothingOn = RankingRules.rank(buses, context: context(preferRail: false))
        XCTAssertEqual(nothingOn.guaranteedIds, ["bus0"], "only the first row without any mode on")
    }

    func testGuaranteedIdsOnlyNameRowsThatSurvivedTheCap() {
        let set = (0..<12).map { journey("bus\($0)", [(.walk, 2), (.bus, 30 + $0), (.walk, 2)]) }
        let ranked = RankingRules.rank(set, context: context(preferRail: false, enabled: [.bus]))
        XCTAssertEqual(ranked.itineraries.count, RankingRules.maxResults)
        XCTAssertTrue(ranked.guaranteedIds.isSubset(of: Set(ranked.itineraries.map(\.id))))
        XCTAssertEqual(ranked.guaranteedIds, ["bus0"])
    }
}
