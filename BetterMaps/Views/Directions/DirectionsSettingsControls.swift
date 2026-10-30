import SwiftUI

/// Settings' Directions section: the per-trip controls plus the options few
/// people change per journey (how many changes, the rail preference, rain
/// awareness), each with a line saying what it does. The sheet shows only
/// `DirectionsTripControls`; these live here so the sheet stays short.
struct DirectionsSettingsControls: View {
    let prefs: DirectionsPreferencesSnapshot
    let onChange: (DirectionsPreferencesSnapshot) -> Void

    var body: some View {
        DirectionsTripControls(prefs: prefs, onChange: onChange)

        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: Binding(
                get: { prefs.maxTransfers },
                set: { onChange(prefs.replacing(maxTransfers: $0)) }
            ), in: 0...3) {
                HStack {
                    Label("Max changes", systemImage: "arrow.triangle.swap")
                        .font(.subheadline)
                    Spacer()
                    Text("\(prefs.maxTransfers)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .accessibilityValue("\(prefs.maxTransfers)")
            footnote("How many times you are willing to change vehicle.")
        }

        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { prefs.preferRail },
                set: { onChange(prefs.replacing(preferRail: $0)) }
            )) {
                Label("Prefer rail", systemImage: "tram.fill")
                    .font(.subheadline)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("directions.preferRail")
            footnote("Puts a Luas, DART or train option first when its walks stay short.")
        }

        if prefs.preferRail {
            Stepper(value: Binding(
                get: { prefs.preferRailWalkCeilingMinutes },
                set: { onChange(prefs.replacing(preferRailWalkCeilingMinutes: $0)) }
            ), in: 5...40, step: 5) {
                HStack {
                    Text("If walking totals ≤")
                        .font(.subheadline)
                    Spacer()
                    Text("\(prefs.preferRailWalkCeilingMinutes) min")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .accessibilityLabel("Prefer rail if walking totals up to")
            .accessibilityValue("\(prefs.preferRailWalkCeilingMinutes) minutes")
        }

        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { prefs.rainAware },
                set: { onChange(prefs.replacing(rainAware: $0)) }
            )) {
                Label("Rain aware", systemImage: "cloud.rain")
                    .font(.subheadline)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("directions.rainAware")
            footnote("When rain is likely, options with shorter walks are shown first.")
        }

        if prefs.rainAware {
            Stepper(value: Binding(
                get: { prefs.rainProbabilityThreshold },
                set: { onChange(prefs.replacing(rainProbabilityThreshold: $0)) }
            ), in: 20...90, step: 10) {
                HStack {
                    Text("Rain chance ≥")
                        .font(.subheadline)
                    Spacer()
                    Text("\(prefs.rainProbabilityThreshold) %")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .accessibilityLabel("Rain chance at least")
            .accessibilityValue("\(prefs.rainProbabilityThreshold) percent")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}
