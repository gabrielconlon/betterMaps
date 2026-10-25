import SwiftUI

/// Close control for a map card (stop, place, trail) on the Mac.
///
/// On iPhone a card is closed by swiping it down. A Mac has no swipe, and a
/// sheet there shows no grabber to drag, so without this a stop's timetable
/// could not be closed at all. It adds a close button in a strip above the
/// card's content (an overlay would sit on the card's own trailing buttons,
/// such as the stop's pin star) bound to Escape. Clicking the map also closes
/// a card on the Mac (`MapScreen.handleTap`). Nothing changes on iPhone.
private struct MapCardCloseButton: ViewModifier {
    let onClose: () -> Void

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .help("Close (Esc)")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        #else
        content
        #endif
    }
}

extension View {
    func mapCardCloseButton(onClose: @escaping () -> Void) -> some View {
        modifier(MapCardCloseButton(onClose: onClose))
    }
}
