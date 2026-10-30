import SwiftUI

/// "Routing by Transitous · OpenStreetMap", linked to their source and
/// licence pages. Caption-sized so it never competes with the results.
struct DirectionsAttributionFooter: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Routing by")
            Link("Transitous", destination: URL(string: "https://transitous.org/sources/")!)
            Text("·")
            Link("OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
