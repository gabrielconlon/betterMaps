import SwiftUI
import SwiftData

struct WeatherRuleFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let rule: WeatherRule?

    @State private var name: String = ""
    @State private var conditionType: String = "rain"
    @State private var temperatureThreshold: Double = 32.0
    @State private var windSpeedThreshold: Double = 25.0
    @State private var suppressedMode: String = "walking"
    @State private var actionType: String = "deprioritize"
    @State private var isEnabled: Bool = true

    var isEditing: Bool { rule != nil }

    let conditionTypes = [
        ("rain", "Precipitation", "cloud.rain.fill"),
        ("temperature", "Cold Temperature", "thermometer.snowflake"),
        ("wind", "High Wind", "wind"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule Name") {
                    TextField("e.g., Don't walk in rain", text: $name)
                }

                Section("When") {
                    Picker("Condition", selection: $conditionType) {
                        ForEach(conditionTypes, id: \.0) { type in
                            Label(type.1, systemImage: type.2)
                                .tag(type.0)
                        }
                    }

                    if conditionType == "temperature" {
                        HStack {
                            Text("Temperature below")
                            Spacer()
                            TextField("", value: $temperatureThreshold, format: .number)
                                .keyboardType(.decimalPad)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                            Text("\u{00B0}F")
                        }
                    }

                    if conditionType == "wind" {
                        HStack {
                            Text("Wind above")
                            Spacer()
                            TextField("", value: $windSpeedThreshold, format: .number)
                                .keyboardType(.decimalPad)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                            Text("mph")
                        }
                    }
                }

                Section("Then") {
                    Picker("Affect", selection: $suppressedMode) {
                        ForEach(TransportMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .tag(mode.rawValue)
                        }
                    }

                    Picker("Action", selection: $actionType) {
                        Text("Show warning").tag("deprioritize")
                        Text("Hide route entirely").tag("suppress")
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle(isEditing ? "Edit Rule" : "New Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if let rule {
                    name = rule.name
                    conditionType = rule.conditionType
                    temperatureThreshold = rule.temperatureThresholdF
                    windSpeedThreshold = rule.windSpeedThresholdMPH
                    suppressedMode = rule.suppressedMode
                    actionType = rule.actionType
                    isEnabled = rule.isEnabled
                }
            }
        }
    }

    private func save() {
        if let rule {
            rule.name = name
            rule.conditionType = conditionType
            rule.temperatureThresholdF = temperatureThreshold
            rule.windSpeedThresholdMPH = windSpeedThreshold
            rule.suppressedMode = suppressedMode
            rule.actionType = actionType
            rule.isEnabled = isEnabled
        } else {
            let newRule = WeatherRule(
                name: name,
                conditionType: conditionType,
                temperatureThresholdF: temperatureThreshold,
                windSpeedThresholdMPH: windSpeedThreshold,
                suppressedMode: suppressedMode,
                actionType: actionType,
                isEnabled: isEnabled
            )
            modelContext.insert(newRule)
        }
        dismiss()
    }
}
