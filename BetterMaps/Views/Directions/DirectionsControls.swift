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
                // Two columns: four icon-and-name chips do not fit one row at
                // iPhone width and were truncating to "B…", "L…", "D…".
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Self.modes) { mode in
                        let on = prefs.enabledModes.contains(mode)
                        Button {
                            var modes = prefs.enabledModes
                            if on { modes.remove(mode) } else { modes.insert(mode) }
                            onChange(prefs.replacing(enabledModes: modes))
                        } label: {
                            ModeChipLabel(mode: mode, isOn: on)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mode.displayName)
                        .accessibilityValue(on ? "On" : "Off")
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("directions.mode.\(mode.rawValue)")
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

/// One "Travel by" chip. On is the network's colour, filled, with a tick;
/// off is grey and outlined with no colour at all. A bordered toggle button
/// tinted per network read the same either way (an off Bus chip was still
/// blue and looked on), so the two states differ in fill, colour and glyph.
private struct ModeChipLabel: View {
    let mode: TransitMode
    let isOn: Bool

    var body: some View {
        let tint = TransitColors.pin(mode.layerKind ?? .bus)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: mode.systemImage)
            Text(mode.displayName)
                .lineLimit(1)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
            }
        }
        .font(.subheadline.weight(.medium))
        // The network colours are pastels: dark text on them, not white.
        .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background { if isOn { shape.fill(tint) } }
        .overlay { if !isOn { shape.strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) } }
        .contentShape(shape)
    }
}
