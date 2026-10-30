import SwiftUI

/// A tinted toggle tile for one layer, as the Layers card's compact square
/// (icon over label; transit networks and map styles) or the welcome's wide
/// row (icon, name, checkmark). Tinted `color` when on, grey when off.
struct LayerTile: View {
    enum Style {
        /// 48 pt square for a six-up strip.
        case compact
        /// 64 pt row for a two-column grid.
        case row
    }

    let title: String
    let systemImage: String
    let color: Color
    let isOn: Bool
    var style: Style = .compact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .background(isOn ? color.opacity(0.25) : Color(.systemGray5),
                            in: RoundedRectangle(cornerRadius: style == .compact ? 8 : 12))
                .foregroundStyle(isOn ? color : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .compact:
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        case .row:
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 28)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
        }
    }
}

/// `LayerTile` for one transit network, with the same accessibility label,
/// value ("Shown"/"Hidden") and hint ("Shows Bus"/"Hides Bus") wherever it
/// appears, so the Layers card and the welcome read the same to VoiceOver
/// and to the UI tests.
struct TransitKindTile: View {
    let kind: TransitLayerKind
    let isOn: Bool
    var style: LayerTile.Style = .compact
    let action: () -> Void

    var body: some View {
        LayerTile(title: kind.displayName, systemImage: kind.systemImage,
                  color: TransitColors.pin(kind), isOn: isOn, style: style, action: action)
            .accessibilityValue(isOn ? "Shown" : "Hidden")
            .accessibilityHint(isOn ? "Hides \(kind.displayName)" : "Shows \(kind.displayName)")
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
