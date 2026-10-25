import SwiftUI

/// "MU1 · ✕" capsule under the Layers button while a transit route is drawn.
/// A drawn route used to be clearable only by finding the chip that drew it
/// again; this is the one place that always shows it and always clears it.
struct HighlightedRouteChip: View {
    /// Short name, e.g. "MU1"; nil shows "Route".
    let label: String?
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(TransitColors.highlightedRoute)
                    .accessibilityHidden(true)
                Text(label.map { "Route \($0)" } ?? "Route")
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .accessibilityLabel(label.map { "Clear route \($0) from the map" } ?? "Clear route from the map")
    }
}
