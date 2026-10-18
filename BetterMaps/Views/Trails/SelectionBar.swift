import SwiftUI

/// Floating actions for the selected trail point, shown above the toolbar.
/// Delete is undoable (toast + toolbar Undo), so it needs no confirmation.
struct SelectionBar: View {
    let isEndpoint: Bool
    let onDelete: () -> Void
    let onToggleEndpoint: () -> Void
    let onDeselect: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .foregroundStyle(.red)

            Button(action: onToggleEndpoint) {
                Label(isEndpoint ? "Unmark end" : "Mark start/end",
                      systemImage: isEndpoint ? "flag.slash" : "flag")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }

            Button(action: onDeselect) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Deselect")
        }
        .font(.subheadline.weight(.medium))
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
