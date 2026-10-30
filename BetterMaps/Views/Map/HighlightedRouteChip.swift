import SwiftUI

/// "MU1 · ✕" capsule under the Layers button while a transit route is drawn.
/// A drawn route used to be clearable only by finding the chip that drew it
/// again; this is the one place that always shows it and always clears it.
/// With `prefix: nil` the same chip stands for a drawn directions option.
struct HighlightedRouteChip: View {
    /// Short name, e.g. "MU1"; nil shows "Route".
    let label: String?
    let onClear: () -> Void
    var systemImage: String = "point.topleft.down.to.point.bottomright.curvepath"
    var tint: Color = TransitColors.highlightedRoute
    /// Word before the label ("Route MU1"); nil shows the label alone.
    var prefix: String? = "Route"
    var accessibilityIdentifier: String? = nil

    private var text: String {
        switch (prefix, label) {
        case let (prefix?, label?): return "\(prefix) \(label)"
        case let (nil, label?): return label
        case let (prefix?, nil): return prefix
        case (nil, nil): return "Route"
        }
    }

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(text)
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frame(maxWidth: 240)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .accessibilityLabel(prefix == nil
                            ? "Clear directions to \(label ?? "destination") from the map"
                            : (label.map { "Clear route \($0) from the map" } ?? "Clear route from the map"))
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}
