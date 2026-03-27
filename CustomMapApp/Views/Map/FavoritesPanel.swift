import SwiftUI
import SwiftData

/// Compact quick-toggle panel for transit layers and user place layers.
/// Appears above the bottom bar (near the button that triggers it).
struct FavoritesPanel: View {
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var showLiveTransit: Set<TransitStop.TransitStopType>
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            // User-created place layers
            if !layers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(layers) { layer in
                        layerRow(layer: layer)
                    }
                }

                Divider()
            }

            // Transit toggles
            VStack(spacing: 6) {
                Text("Transit")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                transitRow(type: .bus, icon: "bus.fill", color: .blue, label: "Bus")
                transitRow(type: .luas, icon: "tram.fill", color: .green, label: "Luas")
                transitRow(type: .dart, icon: "tram.fill", color: .orange, label: "DART")
                transitRow(type: .rail, icon: "tram.fill", color: .purple, label: "Rail")
            }

            if !showTransitStops.isEmpty || !showLiveTransit.isEmpty {
                Button(action: {
                    showTransitStops.removeAll()
                    showLiveTransit.removeAll()
                }) {
                    Label("Hide All Transit", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
    }

    // MARK: - User Layer Row

    @ViewBuilder
    private func layerRow(layer: Layer) -> some View {
        Button(action: { layer.isVisible.toggle() }) {
            HStack(spacing: 10) {
                Image(systemName: layer.symbolName)
                    .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                    .frame(width: 20)

                Text(layer.name)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(layer.isVisible ? .blue : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transit Row

    @ViewBuilder
    private func transitRow(type: TransitStop.TransitStopType, icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)

            Text(label)
                .font(.subheadline)
                .frame(width: 40, alignment: .leading)

            Spacer()

            Button(action: { toggleSet(&showTransitStops, type: type) }) {
                Text("Stops")
                    .font(.caption2)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(showTransitStops.contains(type) ? color.opacity(0.2) : Color(.systemGray5))
                    .foregroundStyle(showTransitStops.contains(type) ? color : .secondary)
                    .clipShape(Capsule())
            }

            let liveDisabled = type == .bus && !NTATransitService.isConfigured
            Button(action: { toggleSet(&showLiveTransit, type: type) }) {
                Text("Live")
                    .font(.caption2)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(showLiveTransit.contains(type) ? color.opacity(0.2) : Color(.systemGray5))
                    .foregroundStyle(showLiveTransit.contains(type) ? color : .secondary)
                    .clipShape(Capsule())
            }
            .disabled(liveDisabled)
            .opacity(liveDisabled ? 0.4 : 1)
        }
    }

    private func toggleSet(_ set: inout Set<TransitStop.TransitStopType>, type: TransitStop.TransitStopType) {
        if set.contains(type) { set.remove(type) } else { set.insert(type) }
    }
}
