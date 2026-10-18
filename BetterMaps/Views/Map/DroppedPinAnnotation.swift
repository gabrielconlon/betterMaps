import SwiftUI

/// The pin a long-press drops while the quick-add sheet is open. Falls in
/// from above with a short spring; appears in place under Reduce Motion.
struct DroppedPinAnnotation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "mappin")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 3, height: 12)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .offset(y: landed || reduceMotion ? 0 : -36)
        .opacity(landed || reduceMotion ? 1 : 0)
        .background(alignment: .bottom) {
            Ellipse()
                .fill(.black.opacity(0.2))
                .frame(width: 10, height: 4)
                .offset(y: 2)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.62)) {
                landed = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Dropped pin")
    }
}
