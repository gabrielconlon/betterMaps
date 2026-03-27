import SwiftUI

struct TransitStopPin: View {
    let stop: TransitStop
    let zoomDelta: Double
    /// Optional color override (e.g., combined DART+Rail color)
    var colorOverride: Color?

    var size: AnnotationSize {
        AnnotationSize(latitudeDelta: zoomDelta)
    }

    var color: Color {
        colorOverride ?? Color(hex: stop.type.colorHex) ?? .blue
    }

    var body: some View {
        switch size {
        case .dot:
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        case .compact:
            Image(systemName: stop.type.systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(color)
                .clipShape(Circle())
        case .full:
            VStack(spacing: 0) {
                Image(systemName: stop.type.systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(color)
                    .clipShape(Circle())
                    .shadow(color: color.opacity(0.3), radius: 2, y: 1)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(180))
                    .offset(y: -2)
            }
        }
    }
}
