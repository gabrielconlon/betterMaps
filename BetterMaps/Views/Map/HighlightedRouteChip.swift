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
    /// When set, the label reopens what the chip stands for (the directions
    /// card) and only the ✕ clears. Without it the whole chip clears, as a
    /// favorite route's chip always has.
    var onOpen: (() -> Void)? = nil
    var openAccessibilityLabel: String? = nil

    private var text: String {
        switch (prefix, label) {
        case let (prefix?, label?): return "\(prefix) \(label)"
        case let (nil, label?): return label
        case let (prefix?, nil): return prefix
        case (nil, nil): return "Route"
        }
    }

    var body: some View {
        Group {
            if let onOpen {
                HStack(spacing: 0) {
                    Button(action: onOpen) {
                        HStack(spacing: 6) {
                            icon
                            title
                        }
                        .padding(.leading, 14)
                        .padding(.trailing, 4)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(openAccessibilityLabel ?? text)
                    .accessibilityIdentifier(accessibilityIdentifier.map { "\($0).open" } ?? "")

                    Button(action: onClear) {
                        xmark
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(clearAccessibilityLabel)
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")
                }
                .frame(maxWidth: 260)
            } else {
                Button(action: onClear) {
                    HStack(spacing: 6) {
                        icon
                        title
                        xmark
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .frame(maxWidth: 240)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearAccessibilityLabel)
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
            }
        }
        .font(.subheadline)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(text)
            .foregroundStyle(.primary)
            .fontWeight(.semibold)
            .lineLimit(1)
    }

    private var xmark: some View {
        Image(systemName: "xmark")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var clearAccessibilityLabel: String {
        prefix == nil
            ? "Clear directions to \(label ?? "destination") from the map"
            : (label.map { "Clear route \($0) from the map" } ?? "Clear route from the map")
    }
}
