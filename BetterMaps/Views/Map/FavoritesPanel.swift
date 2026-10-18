import SwiftUI
import SwiftData
import MapKit

enum MapStyleOption: String, CaseIterable {
    case standard = "Standard"
    case muted = "Muted"
    case satellite = "Satellite"
    case hybrid = "Hybrid"

    var icon: String {
        switch self {
        case .standard: return "map"
        case .muted: return "map.fill"
        case .satellite: return "globe.americas"
        case .hybrid: return "square.3.layers.3d.top.filled"
        }
    }
}

/// Quick-access panel covering the three things a user toggles most: transit
/// modes (+ favorited routes), their saved place layers, and the map style.
///
/// LAYOUT — three banded regions, only the middle one scrolls.
///
/// ┌─────────────────────────┐
/// │ Header                  │  fixed
/// ├─────────────────────────┤
/// │ Transit modes + Routes  │  fixed (max ~140pt)
/// ├─────────────────────────┤
/// │ Layers (your places)    │  scrolls — fills remaining
/// ├─────────────────────────┤
/// │ Map Style               │  fixed (~52pt)
/// └─────────────────────────┘
///
/// The previous design wrapped every section in a single ScrollView, which
/// meant a long Layers list could push Transit and Map Style off-screen — and
/// since those two sections are capped at 4 items each they never need to
/// scroll. By splitting into bands, the Layers section (the primary feature
/// per Pareto) gets the full remaining height, while the fixed-size strips
/// stay anchored where the user expects them.
struct FavoritesPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Query(sort: \FavoriteTransitRoute.sortOrder) private var favoriteRoutes: [FavoriteTransitRoute]
    @Binding var showTransitStops: Set<TransitStop.TransitStopType>
    @Binding var isPresented: Bool
    @Binding var mapStyle: MapStyleOption
    /// Called when the user taps a favorited-route chip. Route drawing on the
    /// map was removed with the planner; the host decides what to do here.
    var onSelectRoute: ((FavoriteTransitRoute) -> Void)? = nil

    // Map style favorites stay AppStorage-backed; they're a UI preference,
    // not user data, so SwiftData would be overkill.
    @AppStorage("favMapStandard") private var favStandard = true
    @AppStorage("favMapMuted") private var favMuted = true
    @AppStorage("favMapSatellite") private var favSatellite = true
    @AppStorage("favMapHybrid") private var favHybrid = true

    private var favoriteLayers: [Layer] { layers.filter { $0.isFavorite } }
    private var nonFavoriteLayers: [Layer] { layers.filter { !$0.isFavorite } }

    private var favoriteMapStyles: [MapStyleOption] {
        var result: [MapStyleOption] = []
        if favStandard { result.append(.standard) }
        if favMuted { result.append(.muted) }
        if favSatellite { result.append(.satellite) }
        if favHybrid { result.append(.hybrid) }
        return result
    }

    /// One row per transit mode for the chip strip.
    private struct TransitMode: Identifiable {
        let id: TransitStop.TransitStopType
        let label: String
        let icon: String
        let color: Color
    }
    private static let transitModes: [TransitMode] = [
        .init(id: .bus,  label: "Bus",  icon: "bus.fill",  color: TransitColors.busPin),
        .init(id: .luas, label: "Luas", icon: "tram.fill", color: TransitColors.luasGrnPin),
        .init(id: .dart, label: "DART", icon: "tram.fill", color: TransitColors.dartPin),
        .init(id: .rail, label: "Rail", icon: "tram.fill", color: TransitColors.railPin),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            transitBand
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            layersBand              // ← only band that scrolls; takes the rest
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            mapStyleBand
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Layers")
                .font(.headline)
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transit band (chips + favorite-routes strip)

    private var transitBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Transit")

            // Mode chips: tap toggles stops + lines for that mode.
            HStack(spacing: 6) {
                ForEach(Self.transitModes) { mode in
                    transitModeChip(mode)
                }
            }

            // Favorited specific routes — horizontal scroll, anchored above
            // the layers list. Tap a chip to draw that route on the map.
            if !favoriteRoutes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(favoriteRoutes) { route in
                            routeChip(route)
                        }
                    }
                }
                .frame(height: 32)
            }
        }
    }

    @ViewBuilder
    private func transitModeChip(_ mode: TransitMode) -> some View {
        let isOn = showTransitStops.contains(mode.id)

        VStack(spacing: 2) {
            Image(systemName: mode.icon)
                .font(.system(size: 14, weight: .semibold))
            Text(mode.label)
                .font(.system(size: 10, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isOn ? mode.color.opacity(0.25) : Color(.systemGray5))
        .foregroundStyle(isOn ? mode.color : .secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSet(&showTransitStops, type: mode.id)
        }
    }

    @ViewBuilder
    private func routeChip(_ route: FavoriteTransitRoute) -> some View {
        let bgColor: Color = {
            switch route.routeType {
            case 0: return TransitColors.luasGrnPin   // tram (Luas)
            case 2: return TransitColors.dartPin      // rail (DART/Commuter)
            default: return TransitColors.busPin      // bus
            }
        }()

        Button(action: { onSelectRoute?(route) }) {
            HStack(spacing: 4) {
                Text(route.shortName)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bgColor)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Long-press / right-click access for unpinning. Keeps the
            // primary tap action focused on the "show on map" path.
            Button(role: .destructive) {
                modelContext.delete(route)
            } label: {
                Label("Unpin Route", systemImage: "star.slash")
            }
            if !route.longName.isEmpty {
                Text(route.longName)
            }
        }
    }

    // MARK: - Layers band (scrollable)

    private var layersBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("My Layers")
                Spacer()
                if !showTransitStops.isEmpty {
                    Button(action: {
                        showTransitStops.removeAll()
                    }) {
                        Label("Hide Transit", systemImage: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if !favoriteLayers.isEmpty {
                        sectionHeader("Pinned").padding(.top, 2)
                        ForEach(favoriteLayers) { layer in
                            layerRow(layer: layer)
                        }
                    }
                    if !nonFavoriteLayers.isEmpty {
                        if !favoriteLayers.isEmpty {
                            Divider().padding(.vertical, 2)
                        }
                        sectionHeader("All Layers").padding(.top, 2)
                        ForEach(nonFavoriteLayers) { layer in
                            layerRow(layer: layer)
                        }
                    }
                    if layers.isEmpty {
                        Text("Create layers in the menu to organize your saved places.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Map Style band (compact 4-button row)

    private var mapStyleBand: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Map Style")
            HStack(spacing: 6) {
                ForEach(favoriteMapStyles, id: \.self) { option in
                    Button(action: { mapStyle = option }) {
                        VStack(spacing: 2) {
                            Image(systemName: option.icon)
                                .font(.system(size: 13))
                            Text(option.rawValue)
                                .font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(mapStyle == option ? Color.blue.opacity(0.2) : Color(.systemGray5))
                        .foregroundStyle(mapStyle == option ? .blue : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if favoriteMapStyles.isEmpty {
                Text("Pin map styles in Settings to show them here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func layerRow(layer: Layer) -> some View {
        HStack(spacing: 10) {
            Button(action: { layer.isVisible.toggle() }) {
                HStack(spacing: 10) {
                    Image(systemName: layer.kind == .waypointPath
                          ? "point.topleft.down.to.point.bottomright.curvepath"
                          : layer.symbolName)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { layer.isFavorite.toggle() }) {
                Image(systemName: layer.isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(layer.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleSet(_ set: inout Set<TransitStop.TransitStopType>, type: TransitStop.TransitStopType) {
        if set.contains(type) { set.remove(type) } else { set.insert(type) }
    }
}
