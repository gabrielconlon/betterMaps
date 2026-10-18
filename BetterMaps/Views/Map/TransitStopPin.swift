import SwiftUI

/// A transit stop pin. Tappable at every zoom: the far-zoom dot sits in a
/// 24pt hit area, the larger sizes keep the 44pt HIG target.
struct TransitStopPin: View {
    let stop: TransitStop
    let size: AnnotationSize
    /// Optional color override (e.g., Luas Red vs Green line)
    var colorOverride: Color?

    var color: Color {
        colorOverride ?? Color(hex: stop.type.colorHex) ?? .blue
    }

    var body: some View {
        switch size {
        case .dot:
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        case .compact:
            Image(systemName: stop.type.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(color)
                .clipShape(Circle())
                .frame(minWidth: 44, minHeight: 44) // Apple HIG minimum tap target
                // Rectangle (not Circle) so the full 44x44 frame accepts taps —
                // an inscribed circle leaves ~32% of the corner area dead, and
                // those misses fall through to the map's POI search debounce.
                .contentShape(Rectangle())
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
            .contentShape(Rectangle())
        }
    }
}
