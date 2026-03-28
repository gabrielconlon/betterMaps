import SwiftUI
import SwiftData

struct PlaceSearchView: View {
    @Query(sort: \Place.name) private var allPlaces: [Place]
    @State private var searchText = ""
    @State private var filterRating: Int = 0

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

        return result
    }

    var body: some View {
        List {
            if filterRating > 0 {
                Section {
                    HStack {
                        Text("Minimum rating:")
                        RatingDisplayView(rating: filterRating)
                        Spacer()
                        Button("Clear") { filterRating = 0 }
                            .font(.caption)
                    }
                }
            }

            Section("\(filteredPlaces.count) places") {
                ForEach(filteredPlaces) { place in
                    PlaceRowView(place: place)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search by name, tag, or notes")
        .navigationTitle("All Places")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}
