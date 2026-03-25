import SwiftUI
import SwiftData

struct WeatherRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WeatherRule.createdAt) private var rules: [WeatherRule]
    @State private var showNewRuleForm = false

    var body: some View {
        List {
            Section {
                Text("Weather rules adjust route recommendations based on current conditions at your destination.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Active Rules") {
                if rules.isEmpty {
                    Text("No weather rules configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        NavigationLink(destination: WeatherRuleFormView(rule: rule)) {
                            WeatherRuleRow(rule: rule)
                        }
                    }
                    .onDelete(perform: deleteRules)
                }
            }
        }
        .navigationTitle("Weather Rules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showNewRuleForm = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewRuleForm) {
            WeatherRuleFormView(rule: nil)
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(rules[index])
        }
    }
}

struct WeatherRuleRow: View {
    @Bindable var rule: WeatherRule

    var body: some View {
        HStack {
            Image(systemName: iconForCondition(rule.conditionType))
                .foregroundStyle(rule.isEnabled ? .blue : .gray)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? describeRule(rule) : rule.name)
                    .font(.body)
                Text(describeRule(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
        }
    }

    private func iconForCondition(_ condition: String) -> String {
        switch condition {
        case "rain": return "cloud.rain.fill"
        case "temperature": return "thermometer.snowflake"
        case "wind": return "wind"
        default: return "cloud"
        }
    }

    private func describeRule(_ rule: WeatherRule) -> String {
        let action = rule.actionType == "suppress" ? "Hide" : "Warn about"
        let mode = rule.suppressedMode

        switch rule.conditionType {
        case "rain":
            return "\(action) \(mode) when raining"
        case "temperature":
            return "\(action) \(mode) below \(Int(rule.temperatureThresholdF))\u{00B0}F"
        case "wind":
            return "\(action) \(mode) above \(Int(rule.windSpeedThresholdMPH)) mph wind"
        default:
            return "\(action) \(mode)"
        }
    }
}
