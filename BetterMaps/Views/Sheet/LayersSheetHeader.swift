import SwiftUI

/// Always-visible top of the sheet: search field, "+" menu (and the gear or
/// Cancel button), then the "Overlap only" toggle (once two place layers are
/// showing) and one chip per layer and transit network.
struct LayersSheetHeader: View {
    /// User layers in sortOrder.
    let layers: [Layer]
    @Bindable var filterVM: LayerFilterViewModel
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
        // Chips carry their own 5 pt vertical hit padding (44 pt targets), so
        // no extra spacing: grabber + 44 + 44 still fits the collapsed sheet.
        VStack(spacing: 0) {
            searchRow
            chipRow
        }
    }

    private var visiblePlaceLayerCount: Int {
        layers.reduce(0) { $1.isVisible && $1.kind == .places ? $0 + 1 : $0 }
    }

    /// The overlap filter only means something with two place layers showing.
    private var showsOverlapToggle: Bool { visiblePlaceLayerCount >= 2 }

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
                if showsOverlapToggle {
                    OverlapToggleChip(isOn: filterVM.filterMode == .intersection) {
                        let turningOn = filterVM.filterMode != .intersection
                        filterVM.filterMode = turningOn ? .intersection : .union
                        if turningOn { markHint(.overlap) }
                    }
                    .transition(.opacity)
                    Divider().frame(height: 22)
                }
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
                              colorHex: kind == .luas ? TransitColors.luasRedPinHex : TransitColors.pinHex(kind),
                              secondaryColorHex: kind == .luas ? TransitColors.luasGrnPinHex : nil,
                              isOn: transitSettings.isEnabled(kind)) {
                        transitSettings.toggle(kind)
                        markToggled()
                    }
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.2), value: showsOverlapToggle)
        }
    }

    private func markToggled() { markHint(.toggleLayer) }

    private func markHint(_ hint: FirstRunHints.Hint) {
        var hints = FirstRunHints(rawValue: hintsRaw)
        hints.markDone(hint)
        if hints.rawValue != hintsRaw { hintsRaw = hints.rawValue }
    }
}

/// "Overlap only": shows just the places in every visible place layer.
/// Off (the default) shows everything. Dark-on-white when on, matching the
/// overlap pins' black-and-white treatment.
struct OverlapToggleChip: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle.circle")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Overlap only")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(isOn ? Color.primary : Color(.secondarySystemFill), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.5), lineWidth: 1.5) }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel("Overlap only")
        .accessibilityValue(isOn ? "On" : "Off, showing everything")
        .accessibilityHint(isOn ? "Shows places in any visible layer"
                                : "Shows only places that are in every visible layer")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Capsule toggle: filled with the layer color when visible, outlined when
/// hidden. Toggles optimistically with a selection haptic.
struct LayerChip: View {
    let title: String
    let symbol: String
    let colorHex: String
    /// Second line colour (Luas red/green): the chip shows a split dot and a
    /// half-and-half fill instead of one colour.
    var secondaryColorHex: String? = nil
    let isOn: Bool
    let action: () -> Void

    private var color: Color { Color(hex: colorHex) ?? .red }
    private var secondaryColor: Color? { secondaryColorHex.flatMap { Color(hex: $0) } }

    /// Hard-stop left/right split for two-line networks.
    private func split(_ a: Color, _ b: Color) -> LinearGradient {
        LinearGradient(stops: [.init(color: a, location: 0), .init(color: a, location: 0.5),
                               .init(color: b, location: 0.5), .init(color: b, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private var fill: AnyShapeStyle {
        guard isOn else { return AnyShapeStyle(Color(.secondarySystemFill)) }
        if let secondaryColor { return AnyShapeStyle(split(color, secondaryColor)) }
        return AnyShapeStyle(color)
    }

    private var outline: AnyShapeStyle {
        if let secondaryColor { return AnyShapeStyle(split(color, secondaryColor).opacity(isOn ? 0 : 0.8)) }
        return AnyShapeStyle(color.opacity(isOn ? 0 : 0.8))
    }

    private var prefersDarkText: Bool {
        Self.prefersDarkText(hex: colorHex)
            && (secondaryColorHex.map(Self.prefersDarkText(hex:)) ?? true)
    }

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
                if let secondaryColor {
                    splitDot(secondaryColor)
                } else {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? (prefersDarkText ? Color.black : Color.white) : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(outline, lineWidth: 1.5) }
            // Visual capsule stays compact; the tap target is 44 pt tall.
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityHint(isOn ? "Hides the layer" : "Shows the layer")
    }

    /// Red/green halves with a white edge so it reads on either fill.
    private func splitDot(_ second: Color) -> some View {
        Circle()
            .fill(split(color, second))
            .frame(width: 11, height: 11)
            .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
            .accessibilityHidden(true)
    }
}
