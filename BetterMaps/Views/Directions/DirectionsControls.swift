import SwiftUI

/// The travel preferences people change per trip: how far to walk (a slider
/// up to "any distance"), which networks, a direct cycle option and its
/// style. A pure value view used in the sheet's Options disclosure and, with
/// the rarely changed options added, in Settings (`DirectionsSettingsControls`).
/// Every change hands back a whole snapshot.
struct DirectionsTripControls: View {
    let prefs: DirectionsPreferencesSnapshot
    let onChange: (DirectionsPreferencesSnapshot) -> Void

    private static var modes: [TransitMode] { DirectionsControlsOrder.modes }
    private static let steps = DirectionsPreferencesSnapshot.walkToleranceSteps

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text(prefs.walkToleranceLabel)
                    .font(.subheadline)
                Slider(value: Binding(
                    get: { Double(Self.steps.firstIndex(of: prefs.walkToleranceMinutes) ?? 1) },
                    set: { value in
                        let index = min(max(Int(value.rounded()), 0), Self.steps.count - 1)
                        let minutes = Self.steps[index]
                        if minutes != prefs.walkToleranceMinutes {
                            onChange(prefs.replacing(walkToleranceMinutes: minutes))
                        }
                    }
                ), in: 0...Double(Self.steps.count - 1), step: 1) {
                    Text("Walking")
                } minimumValueLabel: {
                    Text("5 min").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Any").font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .accessibilityLabel("Walking")
                .accessibilityValue(prefs.walkToleranceLabel)
                .accessibilityIdentifier("directions.walkSlider")
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
            .accessibilityIdentifier("directions.bikeDirect")

            if prefs.allowBikeDirect {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cycling")
                        .font(.subheadline)
                    Picker("Cycling", selection: Binding(
                        get: { prefs.cyclingStyle },
                        set: { onChange(prefs.replacing(cyclingStyle: $0)) }
                    )) {
                        ForEach(CyclingStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("directions.cyclingStyle")
                }
                .padding(.vertical, 4)
            }
        }
    }
}
