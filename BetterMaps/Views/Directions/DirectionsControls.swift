import SwiftUI

/// The travel preferences people change per trip: how far to walk (a slider
/// up to "any distance"), which networks, a direct cycle option and its
/// style. A pure value view used in the sheet's Options disclosure and, with
/// the rarely changed options added, in Settings (`DirectionsSettingsControls`).
/// Every change hands back a whole snapshot.
struct DirectionsTripControls: View {
    let prefs: DirectionsPreferencesSnapshot
    let onChange: (DirectionsPreferencesSnapshot) -> Void

    /// Where the thumb is while dragging. The label follows it live; the
    /// preference (and the re-plan behind it) is written once, on release.
    @State private var walkIndex: Double

    private static var modes: [TransitMode] { DirectionsControlsOrder.modes }
    private static let steps = DirectionsPreferencesSnapshot.walkToleranceSteps

    init(prefs: DirectionsPreferencesSnapshot, onChange: @escaping (DirectionsPreferencesSnapshot) -> Void) {
        self.prefs = prefs
        self.onChange = onChange
        _walkIndex = State(initialValue: Self.index(of: prefs.walkToleranceMinutes))
    }

    private static func index(of minutes: Int) -> Double {
        Double(steps.firstIndex(of: minutes) ?? 1)
    }

    /// The minutes the thumb points at.
    private var draggedMinutes: Int {
        Self.steps[min(max(Int(walkIndex.rounded()), 0), Self.steps.count - 1)]
    }

    private var walkLabel: String {
        DirectionsPreferencesSnapshot.walkToleranceLabel(forMinutes: draggedMinutes)
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text(walkLabel)
                    .font(.subheadline)
                Slider(value: $walkIndex, in: 0...Double(Self.steps.count - 1), step: 1) {
                    Text("Walking")
                } minimumValueLabel: {
                    Text("5 min").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Any").font(.caption).foregroundStyle(.secondary)
                } onEditingChanged: { editing in
                    guard !editing else { return }
                    let minutes = draggedMinutes
                    if minutes != prefs.walkToleranceMinutes {
                        onChange(prefs.replacing(walkToleranceMinutes: minutes))
                    }
                }
                .frame(minHeight: 44)
                .accessibilityLabel("Walking")
                .accessibilityValue(walkLabel)
                .accessibilityIdentifier("directions.walkSlider")
                // Settings, another device or a "walk any distance" button
                // moved the limit: the thumb follows.
                .onChange(of: prefs.walkToleranceMinutes) { _, minutes in
                    let index = Self.index(of: minutes)
                    if index != walkIndex { walkIndex = index }
                }
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
