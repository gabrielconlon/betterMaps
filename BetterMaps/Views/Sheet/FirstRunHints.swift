import SwiftUI

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
            case .toggleLayer: return "Tap a layer chip to show or hide it"
            case .overlap: return "Turn on two layers to see where they overlap"
            }
        }

        var systemImage: String {
            switch self {
            case .savePlace: return "hand.tap"
            case .toggleLayer: return "circle.lefthalf.filled"
            case .overlap: return "circle.grid.cross"
            }
        }
    }

    static let maxVisible = 3

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

    mutating func markDone(_ hint: Hint) {
        rawValue |= hint.rawValue
    }

    /// Marks hints whose action the user has already performed: any saved
    /// place completes "save a place", two or more visible layers complete
    /// "overlap".
    mutating func update(placeCount: Int, visibleLayerCount: Int) {
        if placeCount > 0 { markDone(.savePlace) }
        if visibleLayerCount >= 2 { markDone(.overlap) }
    }
}

// MARK: - View

/// Dismissible one-line hint rows shown at the top of the sheet's medium
/// content. Renders nothing once every hint is done.
struct FirstRunHintsView: View {
    @Binding var hints: FirstRunHints
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !hints.allDone {
            VStack(spacing: 6) {
                ForEach(hints.visible) { hint in
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
                }
            }
        }
    }
}
