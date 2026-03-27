import SwiftUI

/// Compact quick-toggle panel for transit layers and favorite place layers.
/// Shown as a slide-out from top-left, replacing the old layers-in-hamburger approach.
struct FavoritesPanel: View {
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var showLiveTransit: Set<TransitStop.TransitStopType>
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Divider()

            // Transit type toggles
            VStack(spacing: 8) {
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
        .padding(16)
        .frame(width: 220)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    @ViewBuilder
    private func transitRow(type: TransitStop.TransitStopType, icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)

            Text(label)
                .font(.subheadline)

            Spacer()

            // Stops toggle
            Button(action: { toggleSet(&showTransitStops, type: type) }) {
                Text("Stops")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(showTransitStops.contains(type) ? color.opacity(0.2) : Color(.systemGray5))
                    .foregroundStyle(showTransitStops.contains(type) ? color : .secondary)
                    .clipShape(Capsule())
            }

            // Live toggle
            let liveDisabled = type == .bus && !NTATransitService.isConfigured
            Button(action: { toggleSet(&showLiveTransit, type: type) }) {
                Text("Live")
                    .font(.caption2)
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
