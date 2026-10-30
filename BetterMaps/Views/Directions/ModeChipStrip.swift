import SwiftUI

/// "Walk 3 › Luas Red 13 › DART 26": one coloured chip per leg, wrapping
/// onto further lines when the journey has many legs.
struct ModeChipStrip: View {
    let legs: [Leg]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                HStack(spacing: 4) {
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    chip(for: leg)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legs.map(DirectionsFormat.chipLabel).joined(separator: ", then "))
    }

    private func chip(for leg: Leg) -> some View {
        let color = TransitColors.leg(for: leg)
        return HStack(spacing: 3) {
            Image(systemName: leg.mode.systemImage)
                .font(.caption2.weight(.semibold))
            Text(DirectionsFormat.chipLabel(leg))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(leg.mode == .walk ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
        .background(color.opacity(leg.mode == .walk ? 0.12 : 0.18), in: Capsule())
    }
}
