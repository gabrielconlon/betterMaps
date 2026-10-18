import SwiftUI

/// Far-zoom cluster marker: a filled circle with the member count. Tapping
/// asks the screen to zoom the camera into the cluster's cell.
struct ClusterBubble: View {
    let cluster: ClusterLite
    let onTap: (ClusterLite) -> Void

    private var color: Color { Color(hex: cluster.colorHex) ?? .red }

    /// 32pt base, growing slightly with the count so dense cells read as dense.
    private var diameter: CGFloat {
        switch cluster.count {
        case ..<10: return 32
        case ..<100: return 38
        default: return 44
        }
    }

    var body: some View {
        Text(cluster.count, format: .number)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .frame(width: diameter, height: diameter)
            .background(color)
            .clipShape(Circle())
            .overlay { Circle().stroke(.white, lineWidth: 2) }
            .contentShape(Circle())
            .onTapGesture { onTap(cluster) }
            .accessibilityLabel("\(cluster.count) places")
    }
}
