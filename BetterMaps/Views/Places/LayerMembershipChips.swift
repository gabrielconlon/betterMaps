import SwiftUI
import SwiftData

/// Wrapping multi-select chips, one per place layer: filled with the layer
/// colour and checked when the place is in it. Used by the place detail
/// sheet (applies immediately) and the place form (applies on Save), so a
/// place can be in Brunch *and* Favourites — the overlap the map shows.
/// Callers pass `.places` layers only; trail layers are never offered.
struct LayerMembershipChips: View {
    let layers: [Layer]
    let selected: Set<UUID>
    let onToggle: (Layer) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(layers) { layer in
                chip(for: layer, isOn: selected.contains(layer.id))
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func chip(for layer: Layer, isOn: Bool) -> some View {
        let color = Color(hex: layer.colorHex) ?? .red
        let darkText = LayerChip.prefersDarkText(hex: layer.colorHex)
        return Button { onToggle(layer) } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark" : layer.symbolName)
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
                Text(layer.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? (darkText ? Color.black : Color.white) : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(isOn ? color : Color(.secondarySystemFill), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(isOn ? 0 : 0.8), lineWidth: 1.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layer.name)
        .accessibilityValue(isOn ? "In this layer" : "Not in this layer")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Membership

extension Place {
    @MainActor
    func isMember(of layer: Layer) -> Bool {
        (layers ?? []).contains { $0.id == layer.id }
    }

    /// Adds the place to `layer` if it isn't already there. Bumps
    /// `updatedAt` so the map's snapshot cache notices the change.
    @MainActor
    func addMembership(_ layer: Layer) {
        guard !isMember(of: layer) else { return }
        if layer.places == nil { layer.places = [] }
        layer.places?.append(self)
        updatedAt = Date()
    }

    @MainActor
    func removeMembership(_ layer: Layer) {
        guard isMember(of: layer) else { return }
        // SwiftData keeps the inverse (`Place.layers`) in step.
        layer.places?.removeAll { $0.id == id }
        updatedAt = Date()
    }

    /// Number of place (not trail) layers the place is in.
    @MainActor
    var placeLayerCount: Int {
        (layers ?? []).reduce(0) { $1.kind == .places ? $0 + 1 : $0 }
    }
}
