import SwiftUI

/// A transit stop pin. The far-zoom dot is a bare 6pt circle that ignores
/// touches, so hundreds of them never swallow a pan; a map tap near one is
/// resolved by `TransitLayerStore.nearestDotStop`. The larger sizes keep the
/// 44pt HIG target and their own tap.
struct TransitStopPin: View {
    let stop: TransitStop
    let size: AnnotationSize

    /// Network color; Luas Red-line stops are coral.
    var color: Color { TransitColors.pin(for: stop) }

    var body: some View {
        switch size {
        case .dot:
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .allowsHitTesting(false)
        case .compact:
            Image(systemName: stop.kind.systemImage)
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
                Image(systemName: stop.kind.systemImage)
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
