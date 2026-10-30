import SwiftUI

/// The travel preferences, as rows: how far to walk, which networks, a
/// direct cycle option, how many changes. A pure value view shared by the
/// directions sheet and Settings; every change hands back a whole snapshot.
struct DirectionsControls: View {
    let prefs: DirectionsPreferencesSnapshot
    let onChange: (DirectionsPreferencesSnapshot) -> Void

    private static var modes: [TransitMode] { DirectionsControlsOrder.modes }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Walk up to")
                    .font(.subheadline)
                Picker("Walk up to", selection: Binding(
                    get: { prefs.walkToleranceMinutes },
                    set: { onChange(prefs.replacing(walkToleranceMinutes: $0)) }
                )) {
                    ForEach(DirectionsPreferencesSnapshot.walkToleranceSteps, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Travel by")
                    .font(.subheadline)
                HStack(spacing: 8) {
                    ForEach(Self.modes) { mode in
                        Toggle(isOn: Binding(
                            get: { prefs.enabledModes.contains(mode) },
                            set: { on in
                                var modes = prefs.enabledModes
                                if on { modes.insert(mode) } else { modes.remove(mode) }
                                onChange(prefs.replacing(enabledModes: modes))
                            }
                        )) {
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .tint(TransitColors.pin(mode.layerKind ?? .bus))
                        .accessibilityLabel(mode.displayName)
                    }
                }
            }
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { prefs.allowBikeDirect },
                set: { onChange(prefs.replacing(allowBikeDirect: $0)) }
            )) {
                Label("Offer cycling the whole way", systemImage: "bicycle")
                    .font(.subheadline)
            }
            .frame(minHeight: 44)

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

            Toggle(isOn: Binding(
                get: { prefs.preferRail },
                set: { onChange(prefs.replacing(preferRail: $0)) }
            )) {
                Label("Prefer rail", systemImage: "tram.fill")
                    .font(.subheadline)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("directions.preferRail")

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

            Toggle(isOn: Binding(
                get: { prefs.rainAware },
                set: { onChange(prefs.replacing(rainAware: $0)) }
            )) {
                Label("Rain aware", systemImage: "cloud.rain")
                    .font(.subheadline)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("directions.rainAware")

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
    }
}
