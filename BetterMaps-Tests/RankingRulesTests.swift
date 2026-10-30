import XCTest
@testable import CustomMapApp

/// Phase 0 ranking is a stable sort by duration then start; `reason` is
/// whatever the caller set and nothing else.
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

    func testReasonIsLeftUntouched() {
        let input = [itinerary("a", duration: 1200, reason: "Fewest changes"),
                     itinerary("b", duration: 600)]
        let ranked = RankingRules.rank(input)
        XCTAssertEqual(ranked.map(\.reason), [nil, "Fewest changes"])
    }

    func testEmptyInputGivesEmptyOutput() {
        XCTAssertTrue(RankingRules.rank([]).isEmpty)
    }
}
