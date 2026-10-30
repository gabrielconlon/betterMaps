import XCTest
@testable import CustomMapApp

/// Captured Transitous `/api/v6/plan` responses under `Fixtures/motis/`.
/// XcodeGen flattens fixture folders into the test bundle, so each file is
/// looked up by its (unique) basename.
enum MotisFixture: String {
    case heuston = "motis_plan_heuston_dunlaoghaire"
    case `default` = "motis_plan_default"
    case shortwalk = "motis_plan_shortwalk"
    case bikewalk = "motis_plan_bikewalk"
    case bike2rail = "motis_plan_bike2rail"
    case arriveby = "motis_plan_arriveby"
    case empty = "motis_plan_empty"

    static let all: [MotisFixture] = [.heuston, .default, .shortwalk, .bikewalk, .bike2rail, .arriveby, .empty]

    private final class Anchor {}

    func data(file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Anchor.self).url(forResource: rawValue, withExtension: "json"),
            "fixture \(rawValue).json missing from test bundle", file: file, line: line)
        return try Data(contentsOf: url)
    }

    func response(file: StaticString = #filePath, line: UInt = #line) throws -> MotisPlanResponse {
        try MotisPlanResponse.decoder().decode(MotisPlanResponse.self, from: data(file: file, line: line))
    }
}
