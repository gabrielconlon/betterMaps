import XCTest
@testable import CustomMapApp

/// Decoding of captured Transitous responses and their mapping to `Itinerary`.
final class MotisResponseDecodingTests: XCTestCase {

    func testEveryFixtureDecodesWithExpectedCounts() throws {
        let expected: [(MotisFixture, Int, Int)] = [
            (.heuston, 3, 0), (.default, 3, 0), (.shortwalk, 3, 0), (.bikewalk, 3, 1),
            (.bike2rail, 3, 0), (.arriveby, 4, 0), (.empty, 0, 0),
        ]
        for (fixture, itineraries, direct) in expected {
            let response = try fixture.response()
            XCTAssertEqual(response.itineraries.count, itineraries, fixture.rawValue)
            XCTAssertEqual(response.direct.count, direct, fixture.rawValue)
        }
    }

    func testMissingArraysDefaultToEmpty() throws {
        let response = try MotisPlanResponse.decoder().decode(MotisPlanResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(response.itineraries.count, 0)
        XCTAssertEqual(response.direct.count, 0)
    }

    func testDatesWithAndWithoutFractionalSecondsDecode() throws {
        let json = """
        {"itineraries":[{"duration":60,"startTime":"2026-11-03T08:36:00Z","endTime":"2026-11-03T08:37:00.500Z",
          "transfers":0,"legs":[{"mode":"WALK","from":{"name":"A","lat":53.3,"lon":-6.2},
          "to":{"name":"B","lat":53.31,"lon":-6.21,"arrival":"2026-11-03T08:37:00.500Z"},
          "duration":60,"startTime":"2026-11-03T08:36:00Z","endTime":"2026-11-03T08:37:00Z",
          "legGeometry":{"points":""}}]}]}
        """
        let response = try MotisPlanResponse.decoder().decode(MotisPlanResponse.self, from: Data(json.utf8))
        let itinerary = try XCTUnwrap(response.itineraries.first)
        XCTAssertEqual(itinerary.startTime.timeIntervalSince1970, 1_793_694_960, accuracy: 0.001)
        XCTAssertEqual(itinerary.endTime.timeIntervalSince1970, 1_793_695_020.5, accuracy: 0.001)
        XCTAssertEqual(itinerary.legs.first?.legGeometry.precision, 6, "precision defaults to 6")
        XCTAssertNil(itinerary.legs.first?.realTime)
    }

    func testHeustonLegModesAndStopIds() throws {
        let response = try MotisFixture.heuston.response()
        let first = MotisMapper.itinerary(response.itineraries[0])
        XCTAssertEqual(first.legs.map(\.mode), [.walk, .luas, .walk, .dart, .walk])
        XCTAssertEqual(first.modes, [.walk, .luas, .walk, .dart, .walk])

        let luas = first.legs[1]
        XCTAssertEqual(luas.fromStopId, "8220GA00387", "feed prefix stripped")
        XCTAssertEqual(luas.toStopId, "8220GA00421")
        XCTAssertEqual(luas.routeShortName, "Red")
        XCTAssertEqual(luas.headsign, "The Point")
        XCTAssertFalse(luas.isRealtime)
        XCTAssertNil(first.legs[0].fromStopId, "an address has no stop id")
        XCTAssertNil(first.legs[0].routeShortName, "walk legs carry no route name")

        let mapped = response.itineraries.map(MotisMapper.itinerary)
        let railLegs = mapped.flatMap(\.legs).filter { $0.mode == .rail }
        XCTAssertEqual(railLegs.count, 1, "the 'rail' short name maps to .rail, not .dart")
        XCTAssertEqual(railLegs.first?.routeShortName, "rail")
        XCTAssertEqual(mapped[1].legs.map(\.mode), [.walk, .luas, .walk, .rail, .walk])
    }

    func testRideLegsHaveIntermediateStopsWithBareIds() throws {
        let response = try MotisFixture.heuston.response()
        let first = MotisMapper.itinerary(response.itineraries[0])
        let luas = first.legs[1]
        XCTAssertEqual(luas.intermediateStops.count, 5)
        XCTAssertEqual(luas.intermediateStops.first?.name, "Museum")
        for stop in luas.intermediateStops {
            let id = try XCTUnwrap(stop.stopId)
            XCTAssertFalse(id.contains("_"), id)
            XCTAssertTrue(stop.time > luas.start && stop.time < luas.end, stop.name)
        }
        XCTAssertEqual(first.legs[3].intermediateStops.count, 10)
        XCTAssertTrue(first.legs[0].intermediateStops.isEmpty)
    }

    func testIntermediateStopWithoutTimesIsSkipped() {
        let t = Date(timeIntervalSince1970: 1_793_781_360)
        let leg = MotisLeg(
            mode: "BUS", from: MotisPlace(name: "A", lat: 53.3, lon: -6.2, stopId: "ie_1"),
            to: MotisPlace(name: "B", lat: 53.31, lon: -6.21, stopId: "ie_2"),
            duration: 600, startTime: t, endTime: t.addingTimeInterval(600),
            legGeometry: MotisPolyline(points: ""),
            intermediateStops: [
                MotisPlace(name: "no times", lat: 53.305, lon: -6.205, stopId: "ie_3"),
                MotisPlace(name: "departure only", lat: 53.306, lon: -6.206, stopId: "ie_4",
                           departure: t.addingTimeInterval(300)),
            ])
        let mapped = MotisMapper.leg(leg)
        XCTAssertEqual(mapped.intermediateStops.map(\.name), ["departure only"])
        XCTAssertEqual(mapped.intermediateStops.first?.stopId, "4")
        XCTAssertEqual(mapped.id, "BUS|\(t.timeIntervalSince1970)|A", "no trip id falls back to the mode")
    }

    func testWalkAndBikeSecondsAreSummedFromLegs() throws {
        let heuston = try MotisFixture.heuston.response()
        let motisFirst = heuston.itineraries[0]
        let first = MotisMapper.itinerary(motisFirst)
        let expectedWalk = motisFirst.legs.filter { $0.mode == "WALK" }.reduce(0) { $0 + $1.duration }
        XCTAssertGreaterThan(expectedWalk, 0)
        XCTAssertEqual(first.walkSeconds, expectedWalk)
        XCTAssertEqual(first.bikeSeconds, 0)
        XCTAssertEqual(first.durationSeconds, 2880)
        XCTAssertEqual(first.transfers, 1)
        XCTAssertEqual(first.start, motisFirst.startTime)
        XCTAssertEqual(first.end, motisFirst.endTime)

        let bike2rail = try MotisFixture.bike2rail.response()
        let cycled = MotisMapper.itinerary(bike2rail.itineraries[0])
        XCTAssertEqual(cycled.legs.map(\.mode), [.bike, .dart, .walk])
        XCTAssertEqual(cycled.bikeSeconds, bike2rail.itineraries[0].legs[0].duration)
        XCTAssertEqual(cycled.walkSeconds, bike2rail.itineraries[0].legs[2].duration)
        XCTAssertGreaterThan(cycled.bikeSeconds, 0)
    }

    func testDirectBikeItineraryIsMergedAfterTransit() throws {
        let response = try MotisFixture.bikewalk.response()
        let merged = MotisMapper.itineraries(from: response, preferences: .default)
        XCTAssertEqual(merged.count, 4)
        let bike = try XCTUnwrap(merged.last)
        XCTAssertEqual(bike.legs.map(\.mode), [.bike])
        XCTAssertEqual(bike.bikeSeconds, 3042)
        XCTAssertGreaterThan(bike.bikeSeconds, 0)
        XCTAssertEqual(bike.walkSeconds, 0)
        XCTAssertTrue(bike.transitLegs.isEmpty)
        XCTAssertEqual(bike.transfers, 0)
        XCTAssertTrue(bike.id.hasPrefix("BIKE|"))
        XCTAssertEqual(Set(merged.map(\.id)).count, 4, "ids are distinct")
    }

    func testEmptyResponseMapsToNoItineraries() throws {
        let response = try MotisFixture.empty.response()
        XCTAssertEqual(MotisMapper.itineraries(from: response, preferences: .default), [])
    }

    func testModeMapping() {
        XCTAssertEqual(MotisMapper.mode("WALK", routeShortName: nil, displayName: nil), .walk)
        XCTAssertEqual(MotisMapper.mode("BIKE", routeShortName: nil, displayName: nil), .bike)
        XCTAssertEqual(MotisMapper.mode("TRAM", routeShortName: "Green", displayName: nil), .luas)
        XCTAssertEqual(MotisMapper.mode("BUS", routeShortName: "39A", displayName: nil), .bus)
        XCTAssertEqual(MotisMapper.mode("COACH", routeShortName: "X1", displayName: nil), .bus)
        XCTAssertEqual(MotisMapper.mode("REGIONAL_RAIL", routeShortName: "DART", displayName: nil), .dart)
        XCTAssertEqual(MotisMapper.mode("REGIONAL_RAIL", routeShortName: "dart", displayName: nil), .dart)
        XCTAssertEqual(MotisMapper.mode("REGIONAL_RAIL", routeShortName: nil, displayName: "Dart"), .dart)
        XCTAssertEqual(MotisMapper.mode("REGIONAL_RAIL", routeShortName: "rail", displayName: "DART"), .rail,
                       "routeShortName wins over displayName")
        XCTAssertEqual(MotisMapper.mode("RAIL", routeShortName: nil, displayName: nil), .rail)
        for rail in ["SUBURBAN", "HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "SUBWAY", "METRO", "REGIONAL_FAST_RAIL"] {
            XCTAssertEqual(MotisMapper.mode(rail, routeShortName: "IC", displayName: nil), .rail, rail)
        }
        XCTAssertEqual(MotisMapper.mode("FERRY", routeShortName: nil, displayName: nil), .bus, "unknown falls back to bus")
    }
}
