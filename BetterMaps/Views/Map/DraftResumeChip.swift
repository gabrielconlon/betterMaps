import SwiftUI

/// "Draft trail · Resume" capsule under the legend while a kept trail draft
/// exists. The ✕ asks before discarding it.
struct DraftResumeChip: View {
    let onResume: () -> Void
    let onDiscard: () -> Void

    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onResume) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.scribble")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Draft trail")
                        .foregroundStyle(.primary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Resume")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resume draft trail")

            Button {
                confirmDiscard = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard draft trail")
        }
        .font(.subheadline)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .confirmationDialog("Discard draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive, action: onDiscard)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The unsaved trail will be lost.")
        }
    }
}
