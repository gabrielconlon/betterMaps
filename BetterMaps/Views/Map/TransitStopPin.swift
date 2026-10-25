import SwiftUI

/// A transit stop pin. The far-zoom dot is a bare 6pt circle that ignores
/// touches, so hundreds of them never swallow a pan; a map tap near one is
/// resolved by `TransitLayerStore.nearestDotStop`. The larger sizes keep the
/// 44pt HIG target and their own tap.
///
/// A bus stop with a known `heading` carries a small arrow on the rim of its
/// circle pointing the way its buses leave, so the two stops either side of a
/// road can be told apart. Annotations don't turn with the map, so the arrow
/// is drawn relative to `mapHeading`.
struct TransitStopPin: View {
    let stop: TransitStop
    let size: AnnotationSize
    /// Camera heading (degrees clockwise from north) the map was settled at.
    var mapHeading: Double = 0

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
                .overlay { headingArrow(radius: 11) }
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
                    .overlay { headingArrow(radius: 13.5) }

                // The direction arrow would read as this pointer when buses
                // head south, so a pin with an arrow drops it (keeping its
                // height, so the pin still sits on the same spot).
                Image(systemName: "triangle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(180))
                    .offset(y: -2)
                    .opacity(stop.heading == nil ? 1 : 0)
            }
            .frame(minWidth: 44, minHeight: 44) // Apple HIG minimum tap target
            .contentShape(Rectangle())
        }
    }

    /// Arrow just outside a circle of `radius`, turned to the stop's heading.
    /// The offset moves only the drawing, so the rotation pivots on the
    /// circle's centre.
    @ViewBuilder
    private func headingArrow(radius: CGFloat) -> some View {
        if let heading = stop.heading {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .shadow(color: .white, radius: 0.5)
                .offset(y: -(radius + 5))
                .rotationEffect(.degrees(Double(heading) - mapHeading))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
