import SwiftUI

/// One tag or trail group in the sheet's management list: swatch with the
/// symbol, name and a count line. Tapping opens its detail; trail groups
/// also get a "Draw" button. Value inputs only (no SwiftData), 56pt tall,
/// every button a 44×44 target. Visibility lives in the layers panel.
struct LayerCard: View {
    let layer: LayerLite
    let subtitle: String
    let onOpen: () -> Void
    /// Starts the trail editor in this trail group.
    var onDraw: (() -> Void)? = nil

    private var isTrailGroup: Bool { layer.kind == .waypointPath }
    private var color: Color { Color(hex: layer.colorHex) ?? .red }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(isTrailGroup ? "Shows the trail group's trails" : "Shows the tag's places")
            if isTrailGroup, let onDraw {
                Button(action: onDraw) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Draw a trail in \(layer.name)")
            }
        }
        .frame(minHeight: 56)
    }

    private var label: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color)
                Image(systemName: isTrailGroup ? LayerKind.waypointPath.systemImage : layer.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    static func placeSummary(count: Int) -> String {
        switch count {
        case 0: return "No places yet"
        case 1: return "1 place"
        default: return "\(count) places"
        }
    }

    /// "3 trails · 4.2 km".
    static func trailSummary(count: Int, meters: Double) -> String {
        guard count > 0 else { return "No trails yet" }
        let noun = count == 1 ? "1 trail" : "\(count) trails"
        guard meters > 0 else { return noun }
        let km = Measurement(value: meters / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
        return "\(noun) · \(km)"
    }
}
