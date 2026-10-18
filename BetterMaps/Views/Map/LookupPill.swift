import SwiftUI

/// Transient status capsule for a tap-on-map place lookup. Shown within
/// 100 ms of the tap (Doherty) and never as an alert.
struct LookupPill: View {
    enum Phase: Equatable {
        case searching
        case nothingFound
    }

    let phase: Phase

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .searching:
                ProgressView()
                    .controlSize(.small)
                Text("Finding place…")
            case .nothingFound:
                Image(systemName: "mappin.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Nothing here — long-press to save a spot")
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
