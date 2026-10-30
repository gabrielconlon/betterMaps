import SwiftUI

/// Round Layers button for the top-left of the map. Tinted while the panel
/// is open; a 44pt target.
struct LayersButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.3.layers.3d")
                .font(.body)
                .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .background {
                    if isOpen {
                        Circle().fill(Color.accentColor.opacity(0.2))
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layers")
        .accessibilityValue(isOpen ? "Open" : "Closed")
        .accessibilityHint(isOpen ? "Closes the layers panel" : "Chooses what's on the map")
    }
}

/// The panel's lists, built from the screen's value snapshot so the panel
/// never touches SwiftData.
struct LayersPanelInput: Equatable {
    /// Tags (place-kind layers) in sortOrder.
    var tags: [LayerLite] = []
    /// Trail groups (waypoint-path layers) in sortOrder.
    var trailGroups: [LayerLite] = []
}

/// The slide-in panel that chooses what the map draws, modelled on the old
/// app's layers panel. Three bands; only the middle one scrolls:
///
/// ┌──────────────────────────┐
/// │ Layers               (×) │  fixed
/// │ Transit: 4 tiles         │  fixed
/// ├──────────────────────────┤
/// │ Tags (Pinned, All tags)  │  scrolls
/// │ Trails                   │
/// ├──────────────────────────┤
/// │ Map Style: 4 tiles       │  fixed
/// └──────────────────────────┘
///
/// Reads only value inputs, the tag filter, the layer switches and the
/// store's whole-map match count (which never changes with the camera).
struct LayersPanel: View {
    let input: LayersPanelInput
    @Bindable var tagFilter: TagFilter
    @Bindable var settings: TransitLayerSettings
    let store: MapContentStore
    @Binding var mapStyle: MapStyleOption
    let onClose: () -> Void
    /// Flips the layer's `isFavorite` (the star).
    let onToggleFavorite: (UUID) -> Void
    /// Flips a trail group's `isVisible` (the eye).
    let onToggleTrailGroup: (UUID) -> Void
    let onNewTag: () -> Void
    /// A tag was selected or Match changed; marks first-run hints.
    var onFilterChanged: () -> Void = {}

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            transitBand
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            // Short lists sit at their natural height; long ones scroll.
            ViewThatFits(in: .vertical) {
                middleBands
                ScrollView(showsIndicators: true) { middleBands }
            }

            Divider()

            mapStyleBand
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Layers")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -10)
            .accessibilityLabel("Close layers")
        }
        .frame(minHeight: 44)
    }

    // MARK: - Transit

    private var transitBand: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Transit")
                Spacer()
                linkButton(settings.isAnyTransitOn ? "Hide transit" : "Show transit",
                           systemImage: settings.isAnyTransitOn ? "eye.slash" : "eye") {
                    if settings.isAnyTransitOn { settings.hideAllTransit() } else { settings.showTransit() }
                }
            }
            HStack(spacing: 6) {
                ForEach(TransitLayerKind.allCases) { kind in
                    TransitKindTile(kind: kind, isOn: settings.isEnabled(kind)) {
                        settings.toggle(kind)
                    }
                }
            }
        }
    }

    // MARK: - Tags + Trails (scrolls)

    private var middleBands: some View {
        VStack(alignment: .leading, spacing: 14) {
            tagsBand
            if !input.trailGroups.isEmpty {
                Divider()
                trailsBand
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pinnedTags: [LayerLite] { input.tags.filter(\.isFavorite) }
    private var otherTags: [LayerLite] { input.tags.filter { !$0.isFavorite } }

    private var tagsBand: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionHeader("Tags")
                Spacer()
                linkButton(settings.showPlaces ? "Hide places" : "Show places",
                           systemImage: settings.showPlaces ? "eye.slash" : "eye") {
                    settings.showPlaces.toggle()
                }
            }

            if input.tags.isEmpty {
                emptyTags
            } else {
                matchRow
                Group {
                    if !pinnedTags.isEmpty {
                        subHeader("Pinned")
                        ForEach(pinnedTags) { tag in tagRow(tag) }
                    }
                    if !otherTags.isEmpty {
                        if !pinnedTags.isEmpty { subHeader("All tags") }
                        ForEach(otherTags) { tag in tagRow(tag) }
                    }
                    if tagFilter.hasSelection {
                        Text(matchSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.top, 4)
                    }
                }
                .opacity(settings.showPlaces ? 1 : 0.5)
            }
        }
    }

    private var matchSummary: String {
        let n = store.matchingPlaceCount
        switch n {
        case 0: return "No places match"
        case 1: return "1 place matches"
        default: return "\(n) places match"
        }
    }

    private var matchRow: some View {
        HStack(spacing: 8) {
            Text("Match")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Match", selection: $tagFilter.match) {
                ForEach(TagMatch.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
            .accessibilityHint("Any shows places with any selected tag. All shows places with every selected tag.")
            .onChange(of: tagFilter.match) { _, _ in onFilterChanged() }
            Spacer(minLength: 0)
            if tagFilter.hasSelection {
                Button("Clear") { tagFilter.clear() }
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Clear tag selection")
            }
        }
        .frame(minHeight: 44)
    }

    private var emptyTags: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No tags yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onNewTag) {
                Label("New tag", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }

    private func tagRow(_ tag: LayerLite) -> some View {
        let color = Color(hex: tag.colorHex) ?? .red
        let selected = tagFilter.isSelected(tag.id)
        return HStack(spacing: 0) {
            Button {
                tagFilter.toggle(tag.id)
                onFilterChanged()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: tag.symbolName)
                        .foregroundStyle(color)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(tag.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(selected ? color : Color.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: selected)
            .accessibilityLabel(tag.name)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityHint(selected ? "Removes this tag from the filter" : "Filters the map by this tag")
            .accessibilityAddTraits(selected ? .isSelected : [])

            starButton(for: tag)
        }
    }

    // MARK: - Trails

    private var trailsBand: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionHeader("Trails")
                Spacer()
                linkButton(settings.showTrails ? "Hide trails" : "Show trails",
                           systemImage: settings.showTrails ? "eye.slash" : "eye") {
                    settings.showTrails.toggle()
                }
            }
            ForEach(input.trailGroups) { group in trailRow(group) }
                .opacity(settings.showTrails ? 1 : 0.5)
        }
    }

    private func trailRow(_ group: LayerLite) -> some View {
        let color = Color(hex: group.colorHex) ?? .red
        return HStack(spacing: 0) {
            Button { onToggleTrailGroup(group.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: LayerKind.waypointPath.systemImage)
                        .foregroundStyle(color)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(group.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: group.isVisible ? "eye.fill" : "eye.slash")
                        .font(.subheadline)
                        .foregroundStyle(group.isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: group.isVisible)
            .accessibilityLabel(group.name)
            .accessibilityValue(group.isVisible ? "Shown" : "Hidden")
            .accessibilityHint(group.isVisible ? "Hides this trail group" : "Shows this trail group")

            starButton(for: group)
        }
    }

    // MARK: - Map style

    private var mapStyleBand: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Map Style")
            HStack(spacing: 6) {
                ForEach(MapStyleOption.allCases) { option in
                    LayerTile(title: option.rawValue, systemImage: option.icon,
                              color: .accentColor, isOn: mapStyle == option) {
                        mapStyle = option
                    }
                    .accessibilityAddTraits(mapStyle == option ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func subHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// Small secondary text link in a band header ("Hide transit").
    private func linkButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
    }

    private func starButton(for layer: LayerLite) -> some View {
        Button { onToggleFavorite(layer.id) } label: {
            Image(systemName: layer.isFavorite ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(layer.isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layer.isFavorite ? "Unpin \(layer.name)" : "Pin \(layer.name)")
    }
}
