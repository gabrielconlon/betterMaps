import SwiftUI
import SwiftData

/// Compact quick-toggle panel for transit layers and user place layers.
/// Appears above the bottom bar (near the button that triggers it).
struct FavoritesPanel: View {
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var showLiveTransit: Set<TransitStop.TransitStopType>
    @Binding var isPresented: Bool

    // Pinned transit types (persisted)
    @AppStorage("favTransitBus") private var favBus = true
    @AppStorage("favTransitLuas") private var favLuas = true
    @AppStorage("favTransitDart") private var favDart = true
    @AppStorage("favTransitRail") private var favRail = true

    private var favoriteLayers: [Layer] {
        layers.filter { $0.isFavorite }
    }

    private var favoriteTransitTypes: [(type: TransitStop.TransitStopType, icon: String, color: Color, label: String)] {
        var result: [(TransitStop.TransitStopType, String, Color, String)] = []
        if favBus { result.append((.bus, "bus.fill", .blue, "Bus")) }
        if favLuas { result.append((.luas, "tram.fill", .green, "Luas")) }
        if favDart { result.append((.dart, "tram.fill", .orange, "DART")) }
        if favRail { result.append((.rail, "tram.fill", .purple, "Rail")) }
        return result
    }

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

            // Pinned place layers
            if !favoriteLayers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(favoriteLayers) { layer in
                        layerRow(layer: layer)
                    }
                }
            }

            // Pinned transit types
            if !favoriteTransitTypes.isEmpty {
                if !favoriteLayers.isEmpty { Divider() }

                VStack(spacing: 6) {
                    ForEach(favoriteTransitTypes, id: \.type) { item in
                        transitRow(type: item.type, icon: item.icon, color: item.color, label: item.label)
                    }
                }
            }

            if favoriteLayers.isEmpty && favoriteTransitTypes.isEmpty {
                Text("Pin layers in Settings to show them here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            }

            if !showTransitStops.isEmpty || !showLiveTransit.isEmpty {
                Button(action: {
                    showTransitStops.removeAll()
                    showLiveTransit.removeAll()
                }) {
                    Label("Hide All", systemImage: "eye.slash")
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
