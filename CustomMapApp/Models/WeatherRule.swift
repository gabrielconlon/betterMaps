import Foundation
import SwiftData

@Model
final class WeatherRule {
    var id: UUID = UUID()
    var name: String = ""
    var conditionType: String = "rain"
    var temperatureThresholdF: Double = 32.0
    var windSpeedThresholdMPH: Double = 25.0
    var suppressedMode: String = "walking"
    var actionType: String = "deprioritize"
    var isEnabled: Bool = true
    var createdAt: Date = Date()

    init(
        name: String = "",
        conditionType: String = "rain",
        temperatureThresholdF: Double = 32.0,
        windSpeedThresholdMPH: Double = 25.0,
        suppressedMode: String = "walking",
        actionType: String = "deprioritize",
        isEnabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.conditionType = conditionType
        self.temperatureThresholdF = temperatureThresholdF
        self.windSpeedThresholdMPH = windSpeedThresholdMPH
        self.suppressedMode = suppressedMode
        self.actionType = actionType
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }
}
