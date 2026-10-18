import SwiftUI
import MapKit

/// Floating map chrome: the legend top-left (with the trail-draft resume
/// chip and the bus zoom prompt under it) and a top-right control stack
/// (user location, map style, compass). Both sit at the top so they never
/// meet the bottom sheet; they fade out while the sheet is expanded and
/// covers them.
struct MapChrome: View {
    let mapScope: Namespace.ID
    let mapStyle: MapStyleOption
    let legendLayers: [LayerLite]
    let legendEntries: [LegendEntry]
    /// Overlap only found nothing shared by this many visible layers.
    var emptyOverlapLayerCount: Int? = nil
    let isHidden: Bool
    /// Shown while a kept trail draft exists.
    var draftChip: DraftResumeChip? = nil
    /// Bus is on but the camera is too far out for bus stops to draw.
    var showsBusZoomPrompt: Bool = false
    /// Location access granted: the system location button can centre the
    /// map. Otherwise a plain button asks for access first.
    var canLocateUser: Bool = true
    var onZoomForBus: () -> Void = {}
    var onRequestLocation: () -> Void = {}
    let onCycleMapStyle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                LegendStrip(layers: legendLayers, entries: legendEntries,
                            emptyOverlapLayerCount: emptyOverlapLayerCount)
                if let draftChip {
                    draftChip
                        .transition(.opacity)
                }
                if showsBusZoomPrompt {
                    busZoomPrompt
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .accessibilityHidden(isHidden)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .animation(.easeInOut(duration: 0.2), value: showsBusZoomPrompt)
    }

    /// Bus stops are culled when zoomed out; say so and offer the fix.
    private var busZoomPrompt: some View {
        Button(action: onZoomForBus) {
            Label("Zoom in to see bus stops", systemImage: "plus.magnifyingglass")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Zooms the map in so bus stops appear")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                locateButton
                Divider().frame(width: 44)
                Button(action: onCycleMapStyle) {
                    Image(systemName: mapStyle.next.icon)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Map style")
                .accessibilityValue(mapStyle.rawValue)
                .accessibilityHint("Switches to \(mapStyle.next.rawValue)")
            }
            .buttonBorderShape(.roundedRectangle(radius: 0))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)

            MapCompass(scope: mapScope)
                .mapControlVisibility(.automatic)
        }
    }

    @ViewBuilder
    private var locateButton: some View {
        if canLocateUser {
            MapUserLocationButton(scope: mapScope)
                .frame(width: 44, height: 44)
                .tint(.accentColor)
        } else {
            // Location is asked for on this first tap, not at launch.
            Button(action: onRequestLocation) {
                Image(systemName: "location")
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show my location")
        }
    }
}
