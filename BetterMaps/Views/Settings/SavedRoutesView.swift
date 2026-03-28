import SwiftUI
import SwiftData
import MapKit

struct SavedRoutesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedRoute.lastUsed, order: .reverse) private var savedRoutes: [SavedRoute]

    var body: some View {
        List {
            if savedRoutes.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No saved routes")
                            .font(.headline)
                        Text("When viewing directions, tap \"Save for Offline\" to store routes locally. They work without internet and never expire.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
            } else {
                Section("\(savedRoutes.count) saved routes") {
                    ForEach(savedRoutes) { route in
                        SavedRouteRow(route: route)
                    }
                    .onDelete(perform: deleteRoutes)
                }

                Section {
                    Button(role: .destructive, action: deleteAll) {
                        Label("Delete All Saved Routes", systemImage: "trash")
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tip: Apple Maps Offline", systemImage: "info.circle")
                        .font(.subheadline.bold())
                    Text("For offline map tiles, go to Settings > Maps > Offline Maps and download your area. Our saved routes will overlay on those offline maps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Saved Routes")
    }

    private func deleteRoutes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(savedRoutes[index])
        }
    }

    private func deleteAll() {
        for route in savedRoutes {
            modelContext.delete(route)
        }
    }
}

struct SavedRouteRow: View {
    let route: SavedRoute

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: route.transportMode.systemImage)
                .foregroundStyle(route.transportMode.color)
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(route.name.isEmpty ? "\(route.originName) → \(route.destinationName)" : route.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(route.transportMode.displayName)
                        .font(.caption)
                    Text(formattedDuration(route.etaSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formattedDistance(route.distanceMeters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let bikeInfo = route.bikeLaneInfo {
                    Text(bikeInfo)
                        .font(.caption2)
                        .foregroundStyle(.teal)
                }

                Text("Saved \(route.savedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        if mins < 60 { return "\(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem == 0 ? "\(hrs) hr" : "\(hrs) hr \(rem) min"
    }

    private func formattedDistance(_ meters: Double) -> String {
        let miles = meters / 1609.34
        return miles < 0.1 ? "\(Int(meters * 3.28084)) ft" : String(format: "%.1f mi", miles)
    }
}
