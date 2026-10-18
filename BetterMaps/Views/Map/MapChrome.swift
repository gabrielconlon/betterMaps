import SwiftUI
import MapKit

/// Floating map chrome: the round Layers button top-left (with the
/// trail-draft resume chip under it) and the locate button and compass
/// top-right. Both sit at the top so they never meet the bottom sheet; they
/// fade out while the sheet is expanded and covers them. No text floats over
/// the map: everything here is a control.
struct MapChrome: View {
    let mapScope: Namespace.ID
    let isHidden: Bool
    let isLayersOpen: Bool
    let onToggleLayers: () -> Void
    /// Shown while a kept trail draft exists.
    var draftChip: DraftResumeChip? = nil
    /// Location access granted: the system location button can centre the
    /// map. Otherwise a plain button asks for access first.
    var canLocateUser: Bool = true
    var onRequestLocation: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                LayersButton(isOpen: isLayersOpen, action: onToggleLayers)
                if let draftChip, !isLayersOpen {
                    draftChip
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
    }

    private var controls: some View {
        VStack(spacing: 10) {
            locateButton
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
