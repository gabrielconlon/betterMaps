import SwiftUI

/// Always-visible top of the sheet: search field, "+" menu (and the gear or
/// Cancel button), then one chip per layer and transit network.
struct LayersSheetHeader: View {
    /// User layers in sortOrder.
    let layers: [Layer]
    @Bindable var searchState: SearchState
    var isSearchFocused: FocusState<Bool>.Binding
    let detent: SheetDetent
    let transitSettings: TransitLayerSettings
    let onSearchTextChanged: () -> Void
    let onCancelSearch: () -> Void
    let onAddPlace: () -> Void
    /// Opens the trail editor; MapScreen picks or creates the trail layer.
    let onDrawTrail: () -> Void
    let onNewLayer: () -> Void
    let onOpenSettings: () -> Void

    @AppStorage(FirstRunHints.storageKey) private var hintsRaw = 0

    var body: some View {
        VStack(spacing: 4) {
            searchRow
            chipRow
        }
        .padding(.bottom, 4)
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search places, stops, routes", text: $searchState.searchText)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused(isSearchFocused)
                    .onChange(of: searchState.searchText) { _, _ in onSearchTextChanged() }
                    .onSubmit { isSearchFocused.wrappedValue = false }
                if !searchState.searchText.isEmpty {
                    Button {
                        searchState.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

            if isSearchFocused.wrappedValue || !searchState.searchText.isEmpty {
                Button("Cancel", action: onCancelSearch)
                    .font(.body)
                    .frame(minHeight: 44)
            } else {
                addMenu
                if detent != .collapsed {
                    circleButton(systemImage: "gearshape", label: "Settings", action: onOpenSettings)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var addMenu: some View {
        Menu {
            Button(action: onAddPlace) { Label("Add place here", systemImage: "mappin.and.ellipse") }
            Button(action: onDrawTrail) { Label("Draw trail", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            Button(action: onNewLayer) { Label("New layer", systemImage: "square.3.layers.3d") }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Add")
    }

    private func circleButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(layers) { layer in
                    LayerChip(title: layer.name,
                              symbol: layer.kind == .waypointPath ? LayerKind.waypointPath.systemImage : layer.symbolName,
                              colorHex: layer.colorHex,
                              isOn: layer.isVisible) {
                        layer.isVisible.toggle()
                        markToggled()
                    }
                }
                if !layers.isEmpty {
                    Divider().frame(height: 22)
                }
                ForEach(TransitLayerKind.allCases) { kind in
                    LayerChip(title: kind.displayName, symbol: kind.systemImage,
                              colorHex: TransitColors.pinHex(kind),
                              isOn: transitSettings.isEnabled(kind)) {
                        transitSettings.toggle(kind)
                        markToggled()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 36)
    }

    private func markToggled() {
        var hints = FirstRunHints(rawValue: hintsRaw)
        hints.markDone(.toggleLayer)
        hintsRaw = hints.rawValue
    }
}

/// Capsule toggle: filled with the layer color when visible, outlined when
/// hidden. Toggles optimistically with a selection haptic.
struct LayerChip: View {
    let title: String
    let symbol: String
    let colorHex: String
    let isOn: Bool
    let action: () -> Void

    private var color: Color { Color(hex: colorHex) ?? .red }

    /// Light fills (yellow, the pastel transit colors) take dark text.
    static func prefersDarkText(hex: String) -> Bool {
        let clean = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return false }
        func lin(_ c: UInt64) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin((rgb >> 16) & 0xFF) + 0.7152 * lin((rgb >> 8) & 0xFF) + 0.0722 * lin(rgb & 0xFF)
        return l > 0.4
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? (Self.prefersDarkText(hex: colorHex) ? Color.black : Color.white) : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(isOn ? color : Color(.secondarySystemFill), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(isOn ? 0 : 0.8), lineWidth: 1.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityHint(isOn ? "Hides the layer" : "Shows the layer")
    }
}
