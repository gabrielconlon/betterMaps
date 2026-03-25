import SwiftUI

struct PlaceAnnotationView: View {
    let place: Place
    let color: Color
    let symbolName: String

    init(place: Place, layers: [Layer]) {
        self.place = place

        // Use the color/symbol of the first visible layer this place belongs to
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
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(color)
                .clipShape(Circle())
                .shadow(color: color.opacity(0.4), radius: 4, y: 2)

            // Pointer triangle
            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(color)
                .rotationEffect(.degrees(180))
                .offset(y: -3)
        }
    }
}
