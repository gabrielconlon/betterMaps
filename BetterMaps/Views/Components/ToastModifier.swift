import SwiftUI

// MARK: - Model

/// A trailing button on a toast, e.g. "Undo".
struct ToastAction {
    let label: String
    let handler: @MainActor () -> Void

    init(label: String, handler: @escaping @MainActor () -> Void) {
        self.label = label
        self.handler = handler
    }
}

/// One transient confirmation. Identity is per presentation, so showing the same
/// message twice restarts the auto-dismiss timer and the entrance animation.
struct Toast: Identifiable, Equatable {
    let id: UUID
    let message: String
    let systemImage: String
    let duration: Duration
    let action: ToastAction?

    init(message: String,
         systemImage: String = "checkmark.circle.fill",
         duration: Duration = .seconds(2),
         action: ToastAction? = nil) {
        self.id = UUID()
        self.message = message
        self.systemImage = systemImage
        self.duration = duration
        self.action = action
    }

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Screen-level toast queue so child views (forms, sheets) can confirm an action
/// without owning a local `@State` flag. Inject with `.environment(center)` and
/// render with `.toasts(center)` on the screen that should host the overlay.
@Observable
@MainActor
final class ToastCenter {
    var current: Toast?

    init() {}

    func show(_ message: String,
              systemImage: String = "checkmark.circle.fill",
              action: ToastAction? = nil,
              duration: Duration = .seconds(2)) {
        current = Toast(message: message, systemImage: systemImage, duration: duration, action: action)
    }

    func dismiss() {
        current = nil
    }
}

// MARK: - View modifiers

extension View {
    /// Binding-driven toast. `isPresented` flips back to `false` when the toast
    /// auto-dismisses, is swiped away, or its action is tapped.
    func toast(isPresented: Binding<Bool>,
               message: String,
               systemImage: String = "checkmark.circle.fill",
               duration: Duration = .seconds(2),
               action: ToastAction? = nil) -> some View {
        modifier(ToastModifier(isPresented: isPresented,
                               message: message,
                               systemImage: systemImage,
                               duration: duration,
                               action: action))
    }

    /// Renders whatever `center.current` holds. Attach once per screen.
    func toasts(_ center: ToastCenter) -> some View {
        modifier(ToastCenterModifier(center: center))
    }
}

struct ToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let systemImage: String
    let duration: Duration
    let action: ToastAction?

    @State private var toast: Toast?

    func body(content: Content) -> some View {
        content
            .modifier(ToastHostModifier(toast: $toast))
            .onChange(of: isPresented, initial: true) { _, shown in
                if shown {
                    if toast == nil {
                        toast = Toast(message: message, systemImage: systemImage,
                                      duration: duration, action: action)
                    }
                } else {
                    toast = nil
                }
            }
            .onChange(of: toast?.id) { _, id in
                if id == nil, isPresented { isPresented = false }
            }
    }
}

private struct ToastCenterModifier: ViewModifier {
    @Bindable var center: ToastCenter

    func body(content: Content) -> some View {
        content.modifier(ToastHostModifier(toast: $center.current))
    }
}

/// Shared presentation: bottom-anchored, inside the safe area, auto-dismissing,
/// swipe-down to dismiss, success haptic on present, reduce-motion aware.
private struct ToastHostModifier: ViewModifier {
    @Binding var toast: Toast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(toast: toast) { dismissedID in
                        if self.toast?.id == dismissedID { self.toast = nil }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: toast?.id)
            .sensoryFeedback(.success, trigger: toast?.id) { _, new in new != nil }
    }
}

private struct ToastView: View {
    let toast: Toast
    let onDismiss: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let action = toast.action {
                Spacer(minLength: 4)
                Button(action.label) {
                    action.handler()
                    onDismiss(toast.id)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if value.translation.height > 24 || value.predictedEndTranslation.height > 60 {
                        onDismiss(toast.id)
                    } else {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .accessibilityAction(named: "Dismiss") { onDismiss(toast.id) }
        .task(id: toast.id) {
            // Cancelled automatically if the toast is replaced or removed.
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled else { return }
            onDismiss(toast.id)
        }
    }
}
