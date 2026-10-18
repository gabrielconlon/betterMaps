import SwiftUI
import SwiftData

// MARK: - Model (pure)

/// The three one-line first-run hints and which are done. Stored as a
/// bitmask under `@AppStorage(FirstRunHints.storageKey)`: a set bit means
/// the hint was acted on or dismissed and never shows again.
struct FirstRunHints: Equatable, Sendable {
    static let storageKey = "hints.v1"

    enum Hint: Int, CaseIterable, Identifiable, Sendable {
        case savePlace = 1
        case toggleLayer = 2
        case overlap = 4

        var id: Int { rawValue }

        var text: String {
            switch self {
            case .savePlace: return "Long-press the map to save a place"
            case .toggleLayer: return "Tap Layers to choose what's on the map"
            case .overlap: return "Pick two tags and choose All to see places that have both"
            }
        }

        var systemImage: String {
            switch self {
            case .savePlace: return "hand.tap"
            case .toggleLayer: return "square.3.layers.3d"
            case .overlap: return "circle.grid.cross"
            }
        }
    }

    /// One hint at a time: the first one not yet done.
    static let maxVisible = 1

    private(set) var rawValue: Int

    init(rawValue: Int = 0) {
        // Keep only known bits so a corrupt stored value can't hide future hints.
        self.rawValue = rawValue & Hint.allCases.reduce(0) { $0 | $1.rawValue }
    }

    func isDone(_ hint: Hint) -> Bool { rawValue & hint.rawValue != 0 }

    /// Hints still to show, in display order, capped at `maxVisible`.
    var visible: [Hint] {
        Array(Hint.allCases.filter { !isDone($0) }.prefix(Self.maxVisible))
    }

    var allDone: Bool { visible.isEmpty }

    /// The hint to show now: the first incomplete one, except that "save a
    /// place" is left to the sheet's own empty state while there are no
    /// tags (it says the same thing), and no other hint jumps the queue.
    func current(hasLayers: Bool) -> Hint? {
        guard let first = Hint.allCases.first(where: { !isDone($0) }) else { return nil }
        if first == .savePlace && !hasLayers { return nil }
        return first
    }

    mutating func markDone(_ hint: Hint) {
        rawValue |= hint.rawValue
    }

    /// Marks hints whose action the user has already performed: any saved
    /// place completes "save a place". Having tags never completes
    /// "overlap": only choosing All with two tags picked (or tapping an
    /// overlap pin) does, via `markDone(.overlap)`.
    mutating func update(placeCount: Int, visibleLayerCount _: Int) {
        if placeCount > 0 { markDone(.savePlace) }
    }
}

// MARK: - View

/// One dismissible one-line hint shown at the top of the sheet's medium
/// content. Renders nothing once every hint is done, and nothing while the
/// "No tags yet" empty state already says the same thing.
struct FirstRunHintsView: View {
    @Binding var hints: FirstRunHints
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var layers: [Layer]

    var body: some View {
        if let hint = hints.current(hasLayers: !layers.isEmpty) {
            HStack(spacing: 10) {
                Image(systemName: hint.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(hint.text)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        hints.markDone(hint)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss hint")
            }
            .padding(.leading, 12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .transition(.opacity)
            .id(hint)
        }
    }
}
