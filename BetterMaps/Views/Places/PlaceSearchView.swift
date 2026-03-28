import SwiftUI
import SwiftData

struct PlaceSearchView: View {
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]
    @State private var searchText = ""
    @State private var filterRating: Int = 0
    @State private var filterLayerId: UUID?

    /// Callback when a place is selected — zooms to it on the map.
    var onSelectPlace: ((Place) -> Void)?

    var filteredPlaces: [Place] {
        var result = allPlaces

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) } ||
                $0.notes.localizedCaseInsensitiveContains(searchText)
            }
        }

        if filterRating > 0 {
            result = result.filter { $0.rating >= filterRating }
        }

        if let layerId = filterLayerId {
            result = result.filter { place in
                place.layers?.contains { $0.id == layerId } ?? false
            }
        }

        return result
    }

    var body: some View {
        List {
            // Active filters
            if filterRating > 0 || filterLayerId != nil {
                Section {
                    if filterRating > 0 {
                        HStack {
                            Text("Min rating:")
                            RatingDisplayView(rating: filterRating)
                            Spacer()
                            Button("Clear") { filterRating = 0 }
                                .font(.caption)
                        }
                    }
                    if let layerId = filterLayerId,
                       let layer = allLayers.first(where: { $0.id == layerId }) {
                        HStack {
                            Circle()
                                .fill(Color(hex: layer.colorHex) ?? .gray)
                                .frame(width: 10, height: 10)
                            Text("Layer: \(layer.name)")
                                .font(.subheadline)
                            Spacer()
                            Button("Clear") { filterLayerId = nil }
                                .font(.caption)
                        }
                    }
                }
            }

            Section("\(filteredPlaces.count) places") {
                ForEach(filteredPlaces) { place in
                    Button {
                        onSelectPlace?(place)
                    } label: {
                        PlaceSearchRow(place: place)
                    }
                    .tint(.primary)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search by name, tag, or notes")
        .navigationTitle("All Places")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Rating filter
                    Menu("Filter by Rating") {
                        ForEach(0...5, id: \.self) { rating in
                            Button(action: { filterRating = rating }) {
                                if rating == 0 {
                                    Label("Any rating", systemImage: filterRating == 0 ? "checkmark" : "")
                                } else {
                                    Label(
                                        "\(rating)+ stars",
                                        systemImage: filterRating == rating ? "checkmark" : ""
                                    )
                                }
                            }
                        }
                    }

                    // Layer filter
                    if !allLayers.isEmpty {
                        Menu("Filter by Layer") {
                            Button(action: { filterLayerId = nil }) {
                                Label("All layers", systemImage: filterLayerId == nil ? "checkmark" : "")
                            }
                            Divider()
                            ForEach(allLayers) { layer in
                                Button(action: { filterLayerId = layer.id }) {
                                    Label(layer.name, systemImage: filterLayerId == layer.id ? "checkmark" : "")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}

// MARK: - Place Row with Layer Badges

private struct PlaceSearchRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 10) {
            // Layer color dots
            VStack(spacing: 2) {
                let layers = (place.layers ?? []).sorted { $0.sortOrder < $1.sortOrder }
                if layers.isEmpty {
                    Circle()
                        .fill(.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                } else {
                    ForEach(layers.prefix(3)) { layer in
                        Circle()
                            .fill(Color(hex: layer.colorHex) ?? .gray)
                            .frame(width: 8, height: 8)
                    }
                    if layers.count > 3 {
                        Text("+\(layers.count - 3)")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.body)

                if place.rating > 0 {
                    RatingDisplayView(rating: place.rating)
                }

                HStack(spacing: 8) {
                    if !place.tags.isEmpty {
                        Text(place.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    let layerNames = (place.layers ?? []).map(\.name)
                    if !layerNames.isEmpty {
                        Text(layerNames.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text("No layers")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if !place.notes.isEmpty {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }
}
