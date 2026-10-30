import SwiftUI

/// "Routing by Transitous · OpenStreetMap · Weather by Open-Meteo · Cycling
/// by BRouter", linked to their source and licence pages (Open-Meteo data is
/// CC BY 4.0; BRouter's public server asks for the credit). Caption-sized so
/// it never competes with the results.
struct DirectionsAttributionFooter: View {
    var body: some View {
        // One line where it fits, two or three on a narrow phone.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                routing
                Text("·")
                weather
                Text("·")
                cycling
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { routing }
                HStack(spacing: 4) {
                    weather
                    Text("·")
                    cycling
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { routing }
                HStack(spacing: 4) { weather }
                HStack(spacing: 4) { cycling }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var routing: some View {
        Text("Routing by")
        Link("Transitous", destination: URL(string: "https://transitous.org/sources/")!)
        Text("·")
        Link("OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
    }

    @ViewBuilder
    private var weather: some View {
        Text("Weather by")
        Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
    }

    @ViewBuilder
    private var cycling: some View {
        Text("Cycling by")
        Link("BRouter", destination: URL(string: "https://brouter.de/")!)
    }
}
