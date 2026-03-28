import XCTest
@testable import BetterMapsApp

/// Tests for weather rule matching logic.
/// Since WeatherKit's CurrentWeather can't be easily constructed in tests,
/// we test the rule configuration and matching logic structurally.
final class WeatherEvaluationTests: XCTestCase {

    // MARK: - WeatherRule Construction

    /// Default rain rule should target walking with deprioritize action.
    func testDefaultRainRule() {
        let rule = WeatherRule(
            name: "Rain prefers driving",
            conditionType: "rain",
            suppressedMode: "walking",
            actionType: "deprioritize"
        )
        XCTAssertEqual(rule.conditionType, "rain")
        XCTAssertEqual(rule.suppressedMode, "walking")
        XCTAssertEqual(rule.actionType, "deprioritize")
        XCTAssertTrue(rule.isEnabled)
    }

    /// Temperature rule should store threshold in Fahrenheit.
    func testTemperatureRuleThreshold() {
        let rule = WeatherRule(
            name: "Cold weather",
            conditionType: "temperature",
            temperatureThresholdF: 32.0,
            suppressedMode: "walking",
            actionType: "suppress"
        )
        XCTAssertEqual(rule.temperatureThresholdF, 32.0)
        XCTAssertEqual(rule.actionType, "suppress", "Suppress should hide the route entirely")
    }

    /// Wind rule should store threshold in MPH.
    func testWindRuleThreshold() {
        let rule = WeatherRule(
            name: "High wind",
            conditionType: "wind",
            windSpeedThresholdMPH: 25.0,
            suppressedMode: "cycling",
            actionType: "deprioritize"
        )
        XCTAssertEqual(rule.windSpeedThresholdMPH, 25.0)
        XCTAssertEqual(rule.suppressedMode, "cycling")
    }

    /// Disabled rules should have isEnabled = false.
    func testDisabledRule() {
        let rule = WeatherRule(
            name: "Disabled rule",
            conditionType: "rain",
            suppressedMode: "walking",
            actionType: "suppress",
            isEnabled: false
        )
        XCTAssertFalse(rule.isEnabled)
    }

    // MARK: - Rule Matching Logic

    /// A "deprioritize" rule for walking should match the walking transport mode.
    func testRuleMatchesCorrectMode() {
        let rule = WeatherRule(
            name: "Rain deprioritize walking",
            conditionType: "rain",
            suppressedMode: "walking",
            actionType: "deprioritize"
        )
        XCTAssertEqual(rule.suppressedMode, TransportMode.walking.rawValue)
        XCTAssertNotEqual(rule.suppressedMode, TransportMode.driving.rawValue)
        XCTAssertNotEqual(rule.suppressedMode, TransportMode.cycling.rawValue)
    }

    /// A suppress rule should be distinguished from deprioritize.
    func testSuppressVsDeprioritize() {
        let suppress = WeatherRule(
            name: "Suppress walking",
            conditionType: "rain",
            suppressedMode: "walking",
            actionType: "suppress"
        )
        let deprioritize = WeatherRule(
            name: "Deprioritize walking",
            conditionType: "rain",
            suppressedMode: "walking",
            actionType: "deprioritize"
        )
        XCTAssertNotEqual(suppress.actionType, deprioritize.actionType)
    }

    // MARK: - Dublin Weather Scenarios

    /// Typical Dublin rainy day: walking should be deprioritized, driving preferred.
    /// This tests the rule configuration, not the actual weather API.
    func testDublinRainyDayRuleConfig() {
        let rules = [
            WeatherRule(
                name: "Rain prefers driving",
                conditionType: "rain",
                suppressedMode: "walking",
                actionType: "deprioritize"
            ),
            WeatherRule(
                name: "Rain deprioritize cycling",
                conditionType: "rain",
                suppressedMode: "cycling",
                actionType: "deprioritize"
            ),
        ]

        // Walking should be affected
        let walkingRules = rules.filter { $0.suppressedMode == "walking" && $0.conditionType == "rain" }
        XCTAssertEqual(walkingRules.count, 1)

        // Cycling should be affected
        let cyclingRules = rules.filter { $0.suppressedMode == "cycling" && $0.conditionType == "rain" }
        XCTAssertEqual(cyclingRules.count, 1)

        // Driving should NOT be affected by rain rules
        let drivingRules = rules.filter { $0.suppressedMode == "driving" && $0.conditionType == "rain" }
        XCTAssertEqual(drivingRules.count, 0)

        // Transit should NOT be affected by rain rules
        let transitRules = rules.filter { $0.suppressedMode == "transit" && $0.conditionType == "rain" }
        XCTAssertEqual(transitRules.count, 0)
    }

    /// Winter storm: both temperature and wind rules should trigger.
    func testWinterStormRuleConfig() {
        let rules = [
            WeatherRule(
                name: "Freezing",
                conditionType: "temperature",
                temperatureThresholdF: 32.0,
                suppressedMode: "walking",
                actionType: "suppress"
            ),
            WeatherRule(
                name: "Gale",
                conditionType: "wind",
                windSpeedThresholdMPH: 40.0,
                suppressedMode: "cycling",
                actionType: "suppress"
            ),
        ]

        let walkingSuppressed = rules.filter {
            $0.suppressedMode == "walking" && $0.actionType == "suppress"
        }
        let cyclingSuppressed = rules.filter {
            $0.suppressedMode == "cycling" && $0.actionType == "suppress"
        }

        XCTAssertEqual(walkingSuppressed.count, 1, "Walking should be suppressed in freezing temps")
        XCTAssertEqual(cyclingSuppressed.count, 1, "Cycling should be suppressed in gale winds")
    }

    /// Mild Dublin day (10-15C, light breeze): no rules should trigger.
    func testMildDayNoRulesTriggered() {
        let rules = [
            WeatherRule(
                name: "Cold",
                conditionType: "temperature",
                temperatureThresholdF: 32.0,  // 0C — Dublin rarely hits this
                suppressedMode: "walking",
                actionType: "deprioritize"
            ),
            WeatherRule(
                name: "Wind",
                conditionType: "wind",
                windSpeedThresholdMPH: 25.0,
                suppressedMode: "cycling",
                actionType: "deprioritize"
            ),
        ]

        // On a mild day (12C = 53.6F, wind 10mph), neither threshold is breached
        // Temperature: 53.6F > 32F threshold → rule NOT triggered
        // Wind: 10mph < 25mph threshold → rule NOT triggered
        // We can't test the actual weather evaluation without CurrentWeather,
        // but we can verify the thresholds are set correctly
        XCTAssertEqual(rules[0].temperatureThresholdF, 32.0, "Threshold set at freezing")
        XCTAssertEqual(rules[1].windSpeedThresholdMPH, 25.0, "Threshold set at strong wind")
    }
}
