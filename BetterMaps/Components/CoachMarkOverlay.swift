import SwiftUI

/// One-time overlay shown on first map appearance to highlight key features.
struct CoachMarkOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.3)) { isPresented = false }
                }

            VStack(spacing: 0) {
                // Top-left: Layers button hint
                HStack {
                    coachBubble(
                        icon: "square.3.layers.3d",
                        text: "Toggle transit layers\nand saved places",
                        color: .blue
                    )
                    .padding(.leading, 60)
                    .padding(.top, 80)
                    Spacer()
                }

                Spacer()

                // Center: Map long-press hint
                coachBubble(
                    icon: "hand.tap",
                    text: "Long press to save\na new place",
                    color: .green
                )

                Spacer()

                // Bottom: Search bar hint
                coachBubble(
                    icon: "magnifyingglass",
                    text: "Search places, transit\nstops, and routes",
                    color: .orange
                )
                .padding(.bottom, 80)
            }

            // Dismiss instruction
            VStack {
                Spacer()
                Text("Tap anywhere to dismiss")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 30)
            }
        }
        .transition(.opacity)
    }

    private func coachBubble(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15))
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: color.opacity(0.3), radius: 8)
    }
}
