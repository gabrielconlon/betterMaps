import SwiftUI

/// Top bar: cancel, tap-to-rename name, live length and point count, and a
/// small progress indicator while a snap is in flight.
struct TrailEditorStatusBar: View {
    @Binding var name: String
    let placeholder: String
    let summary: String
    let isSnapping: Bool
    let onCancel: () -> Void

    @State private var isRenaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onCancel) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Cancel")

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField(placeholder, text: $name)
                        .font(.headline)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { isRenaming = false }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { isRenaming = false }
                        }
                } else {
                    Button {
                        isRenaming = true
                        nameFocused = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(name.isEmpty ? placeholder : name)
                                .font(.headline)
                                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Trail name, \(name.isEmpty ? placeholder : name)")
                    .accessibilityHint("Double-tap to rename")
                }
                HStack(spacing: 6) {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    if isSnapping {
                        ProgressView().controlSize(.mini)
                        Text("Following paths…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }
}

/// Bottom thumb-zone toolbar: Undo, Snap to paths, Done.
struct TrailEditorToolbar: View {
    let canUndo: Bool
    @Binding var isSnapped: Bool
    let canFinish: Bool
    let isSaving: Bool
    let onUndo: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .disabled(!canUndo)
            .accessibilityLabel("Undo")

            Toggle(isOn: $isSnapped) {
                Label("Snap to paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(isSnapped ? .accentColor : .secondary)

            Button(action: onDone) {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Done").font(.headline)
                    }
                }
                .frame(minWidth: 64, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canFinish || isSaving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}
