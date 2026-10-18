import SwiftUI

/// Small translucent strip listing the visible layers (swatch + name) and up
/// to three overlap rows such as "Brunch + Favourites · 3". In Overlap only
/// mode with nothing shared it says so ("No places in all 3 layers") rather
/// than leaving a blank map. Renders nothing when no layer is visible.
struct LegendStrip: View {
    /// Visible layers, in display order.
    let layers: [LayerLite]
    let entries: [LegendEntry]
    /// Set when Overlap only finds no place in every visible place layer.
    var emptyOverlapLayerCount: Int? = nil

    var body: some View {
        if !layers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(layers) { layer in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: layer.colorHex) ?? .red)
                            .frame(width: 8, height: 8)
                        Text(layer.name)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                if let emptyOverlapLayerCount {
                    Divider().padding(.vertical, 1)
                    Text("No places in all \(emptyOverlapLayerCount) layers")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !entries.isEmpty {
                    Divider().padding(.vertical, 1)
                    ForEach(entries.prefix(3)) { entry in
                        Text("\(entry.label) · \(entry.count)")
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.08), radius: 2)
            .frame(maxWidth: 180, alignment: .leading)
            .allowsHitTesting(false)
        }
    }
}
