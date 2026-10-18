import SwiftUI
import SwiftData

struct AddPlaceToLayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @Environment(\.mapCenter) private var mapCenter

    let layer: Layer

    @State private var searchText = ""
    @State private var showNewPlaceForm = false

    var availablePlaces: [Place] {
        let layerPlaceIDs = Set((layer.places ?? []).map { $0.id })
        let filtered = allPlaces.filter { !layerPlaceIDs.contains($0.id) }

        if searchText.isEmpty {
            return filtered
        }
        return filtered.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allPlaces.isEmpty {
                    ContentUnavailableView(
                        "No Places Yet",
                        systemImage: "mappin",
                        description: Text("Save your first place, then tag it here.")
                    )
                } else if availablePlaces.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if availablePlaces.isEmpty {
                    ContentUnavailableView(
                        "All Places Added",
                        systemImage: "checkmark.circle",
                        description: Text("Every place already has this tag.")
                    )
                } else {
                    List(availablePlaces) { place in
                        Button(action: { addPlace(place) }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(place.name)
                                    if place.rating > 0 {
                                        RatingDisplayView(rating: place.rating)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search places")
            .navigationTitle("Tag places \(layer.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showNewPlaceForm = true }) {
                        Label("New Place", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewPlaceForm) {
                PlaceFormView(layer: layer, mapCenter: mapCenter)
            }
        }
    }

    private func addPlace(_ place: Place) {
        if layer.places == nil {
            layer.places = []
        }
        layer.places?.append(place)
    }
}
