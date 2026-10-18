import SwiftUI

/// One layer as one card (common region): swatch with the layer symbol,
/// name, a count line, optional accessory buttons and a trailing eye toggle.
/// 56pt tall; every button is a 44×44 target.
struct LayerCardRow<Accessory: View>: View {
    let color: Color
    let symbol: String
    let title: String
    let subtitle: String?
    let isVisible: Bool
    let onToggle: () -> Void
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 4) {
            if let onOpen {
                Button(action: onOpen) { label }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the layer's details")
            } else {
                label
            }
            accessory()
            Button(action: onToggle) {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                    .font(.body)
                    .foregroundStyle(isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide \(title)" : "Show \(title)")
            .sensoryFeedback(.selection, trigger: isVisible)
        }
        .frame(minHeight: 56)
    }

    private var label: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isVisible ? color : color.opacity(0.35))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension LayerCardRow where Accessory == EmptyView {
    init(color: Color, symbol: String, title: String, subtitle: String?, isVisible: Bool,
         onToggle: @escaping () -> Void, onOpen: (() -> Void)? = nil) {
        self.init(color: color, symbol: symbol, title: title, subtitle: subtitle, isVisible: isVisible,
                  onToggle: onToggle, onOpen: onOpen, accessory: { EmptyView() })
    }
}

/// A user layer (places or trails). Tapping the row opens its detail; trail
/// layers also get a "Draw" button.
struct LayerCard: View {
    let layer: Layer
    let onOpen: () -> Void
    let onToggle: () -> Void
    /// TRAIL HOOK: starts the trail editor in this layer.
    let onDraw: () -> Void

    private var isTrailLayer: Bool { layer.kind == .waypointPath }

    var body: some View {
        LayerCardRow(
            color: Color(hex: layer.colorHex) ?? .red,
            symbol: isTrailLayer ? LayerKind.waypointPath.systemImage : layer.symbolName,
            title: layer.name,
            subtitle: subtitle,
            isVisible: layer.isVisible,
            onToggle: onToggle,
            onOpen: onOpen
        ) {
            if isTrailLayer {
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
    }

    private var subtitle: String {
        if isTrailLayer {
            let trails = layer.trails ?? []
            return Self.trailSummary(count: trails.count,
                                     meters: trails.reduce(0) { $0 + $1.distanceMeters })
        }
        return Self.placeSummary(count: layer.places?.count ?? 0)
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
