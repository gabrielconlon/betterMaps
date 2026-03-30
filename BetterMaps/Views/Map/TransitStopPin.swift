import SwiftUI

struct TransitStopPin: View {
    let stop: TransitStop
    let zoomDelta: Double
    /// Optional color override (e.g., combined DART+Rail color)
    var colorOverride: Color?

    var size: AnnotationSize {
        AnnotationSize(latitudeDelta: zoomDelta)
    }

    /// Whether this pin is tappable at the current zoom (dots are too small to tap intentionally)
    var isTappable: Bool { size != .dot }

    var color: Color {
        colorOverride ?? Color(hex: stop.type.colorHex) ?? .blue
    }

    var body: some View {
        switch size {
        case .dot:
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .allowsHitTesting(false) // prevent tiny dots from stealing taps
        case .compact:
            Image(systemName: stop.type.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(color)
                .clipShape(Circle())
                .frame(minWidth: 44, minHeight: 44) // Apple HIG minimum tap target
                .contentShape(Circle())
        case .full:
            VStack(spacing: 0) {
                Image(systemName: stop.type.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(color)
                    .clipShape(Circle())
                    .shadow(color: color.opacity(0.3), radius: 2, y: 1)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(180))
                    .offset(y: -2)
            }
            .frame(minWidth: 44, minHeight: 44) // Apple HIG minimum tap target
            .contentShape(Circle())
        }
    }
}
