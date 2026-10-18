import SwiftUI

// MARK: - Model

/// A compact in-place state for a list, sheet section, or panel.
/// Callers pass finished human copy only; this type never surfaces error codes,
/// domains, or `localizedDescription`.
enum InlineStatus: Equatable {
    case loading(String)
    case empty(title: String,
               hint: String?,
               systemImage: String = "mappin.slash",
               action: (label: String, id: String)?)
    case failed(message: String, retryId: String?)

    static func == (lhs: InlineStatus, rhs: InlineStatus) -> Bool {
        switch (lhs, rhs) {
        case let (.loading(a), .loading(b)):
            return a == b
        case let (.empty(t1, h1, s1, a1), .empty(t2, h2, s2, a2)):
            return t1 == t2 && h1 == h2 && s1 == s2
                && a1?.label == a2?.label && a1?.id == a2?.id
        case let (.failed(m1, r1), .failed(m2, r2)):
            return m1 == m2 && r1 == r2
        default:
            return false
        }
    }
}

// MARK: - View

struct StatusView: View {
    let status: InlineStatus
    var onAction: (String) -> Void = { _ in }

    var body: some View {
        switch status {
        case .loading(let text):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)

        case let .empty(title, hint, systemImage, action):
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let action {
                    Button(action.label) { onAction(action.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 44)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

        case let .failed(message, retryId):
            HStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let retryId {
                    Button("Retry") { onAction(retryId) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

/// Skeleton rows to hold a list's shape while it loads.
struct SkeletonRows: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    init(count: Int = 3) {
        self.count = max(0, count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 10) {
                    Circle()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .frame(width: index.isMultiple(of: 2) ? 160 : 120, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .frame(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
            }
        }
        .foregroundStyle(.quaternary)
        .opacity(pulsing ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                   value: pulsing)
        .onAppear { if !reduceMotion { pulsing = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Overlay helper

extension View {
    /// Overlays a `StatusView` while `status` is non-nil; passes through untouched otherwise.
    func inlineStatus(_ status: InlineStatus?,
                      onAction: @escaping (String) -> Void = { _ in }) -> some View {
        overlay {
            if let status {
                StatusView(status: status, onAction: onAction)
                    .padding(.horizontal, 16)
            }
        }
    }
}
