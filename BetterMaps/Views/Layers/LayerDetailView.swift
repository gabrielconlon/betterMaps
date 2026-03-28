import SwiftUI
import SwiftData

struct LayerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var layer: Layer
    @State private var showEditForm = false
    @State private var showAddPlace = false

    var layerPlaces: [Place] {
        (layer.places ?? []).sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: layer.symbolName)
                        .font(.title)
                        .foregroundStyle(Color(hex: layer.colorHex) ?? .red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(layer.name)
                            .font(.headline)
                        Text("\(layerPlaces.count) places")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $layer.isVisible)
                        .labelsHidden()
                }
            }

            Section("Places") {
                if layerPlaces.isEmpty {
                    Text("No places in this layer yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(layerPlaces) { place in
                        PlaceRowView(place: place)
                    }
                    .onDelete(perform: removePlaces)
                }
            }
        }
        .navigationTitle(layer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showAddPlace = true }) {
                        Label("Add Place", systemImage: "plus")
                    }
                    Button(action: { showEditForm = true }) {
                        Label("Edit Layer", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditForm) {
            LayerFormView(layer: layer)
        }
        .sheet(isPresented: $showAddPlace) {
            AddPlaceToLayerView(layer: layer)
        }
    }

    private func removePlaces(at offsets: IndexSet) {
        let sorted = layerPlaces
        for index in offsets {
            let place = sorted[index]
            layer.places?.removeAll { $0.id == place.id }
        }
    }
}

struct PlaceRowView: View {
    let place: Place

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.body)

                if place.rating > 0 {
                    RatingDisplayView(rating: place.rating)
                }

                if !place.tags.isEmpty {
                    Text(place.tags.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !place.notes.isEmpty {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
