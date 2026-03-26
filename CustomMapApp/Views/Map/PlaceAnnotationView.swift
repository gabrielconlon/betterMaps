import SwiftUI

/// Zoom level thresholds for annotation sizing
enum AnnotationSize {
    case dot       // Far zoom — small colored dot
    case compact   // Medium zoom — small icon, no label
    case full      // Close zoom — full pin with icon and pointer

    init(latitudeDelta: Double) {
        if latitudeDelta > 0.08 {
            self = .dot
        } else if latitudeDelta > 0.02 {
            self = .compact
        } else {
            self = .full
        }
    }
}

struct PlaceAnnotationView: View {
    let place: Place
    let color: Color
    let symbolName: String
    let isOverlap: Bool
    let size: AnnotationSize

    init(place: Place, layers: [Layer], isOverlapMode: Bool = false, zoomDelta: Double = 0.01) {
        self.place = place

        let visibleLayers = (place.layers ?? []).filter { $0.isVisible }.sorted { $0.sortOrder < $1.sortOrder }
        if let first = visibleLayers.first {
            self.color = Color(hex: first.colorHex) ?? .red
            self.symbolName = first.symbolName
        } else if let first = place.layers?.first {
            self.color = Color(hex: first.colorHex) ?? .red
            self.symbolName = first.symbolName
        } else {
            self.color = .red
            self.symbolName = "mappin"
        }

        self.isOverlap = isOverlapMode && visibleLayers.count > 1
        self.size = AnnotationSize(latitudeDelta: zoomDelta)
    }

    var pinColor: Color {
        isOverlap ? .purple : color
    }

    var body: some View {
        switch size {
        case .dot:
            dotView
        case .compact:
            compactView
        case .full:
            fullView
        }
    }

    // MARK: - Dot (far zoom)

    private var dotView: some View {
        Circle()
            .fill(pinColor)
            .frame(width: 8, height: 8)
            .shadow(color: pinColor.opacity(0.5), radius: 2)
    }

    // MARK: - Compact (medium zoom)

    private var compactView: some View {
        Image(systemName: isOverlap ? "circle.grid.cross.fill" : symbolName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(pinColor)
            .clipShape(Circle())
            .shadow(color: pinColor.opacity(0.4), radius: 2, y: 1)
    }

    // MARK: - Full (close zoom)

    private var fullView: some View {
        VStack(spacing: 0) {
            ZStack {
                if isOverlap {
                    Circle()
                        .stroke(Color.purple, lineWidth: 3)
                        .frame(width: 38, height: 38)
                    multiLayerDots
                }

                Image(systemName: isOverlap ? "circle.grid.cross.fill" : symbolName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(pinColor)
                    .clipShape(Circle())
                    .shadow(color: pinColor.opacity(0.4), radius: 4, y: 2)
            }

            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(pinColor)
                .rotationEffect(.degrees(180))
                .offset(y: -3)
        }
    }

    @ViewBuilder
    private var multiLayerDots: some View {
        let visibleLayers = (place.layers ?? []).filter { $0.isVisible }.prefix(4)
        HStack(spacing: 2) {
            ForEach(Array(visibleLayers), id: \.id) { layer in
                Circle()
                    .fill(Color(hex: layer.colorHex) ?? .red)
                    .frame(width: 5, height: 5)
            }
        }
        .offset(y: 20)
    }
}
