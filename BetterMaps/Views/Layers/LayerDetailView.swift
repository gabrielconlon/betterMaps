import SwiftUI
import SwiftData

struct LayerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var layer: Layer
    @State private var showEditForm = false
    @State private var showAddPlace = false
    @State private var showAddWaypoint = false

    var layerPlaces: [Place] {
        (layer.places ?? []).sorted { $0.name < $1.name }
    }

    var isWaypointPath: Bool { layer.kind == .waypointPath }

    var pointsLabel: String {
        let count = layerPlaces.count
        return isWaypointPath ? "\(count) waypoints" : "\(count) places"
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
                        Text(pointsLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $layer.isVisible)
                        .labelsHidden()
                }
            }

            if isWaypointPath {
                Section {
                    Text("Each waypoint connects to its two nearest neighbors. Mark a waypoint as a Start/End to connect it to only its single closest neighbor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(isWaypointPath ? "Waypoints" : "Places") {
                if layerPlaces.isEmpty {
                    Text(isWaypointPath
                        ? "No waypoints yet. Add at least two to draw a path."
                        : "No places in this layer yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(layerPlaces) { place in
                        if isWaypointPath {
                            WaypointRowView(place: place)
                        } else {
                            PlaceRowView(place: place)
                        }
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
                    if isWaypointPath {
                        Button(action: { showAddWaypoint = true }) {
                            Label("Add Waypoint", systemImage: "plus")
                        }
                    } else {
                        Button(action: { showAddPlace = true }) {
                            Label("Add Place", systemImage: "plus")
                        }
                    }
                    Button(action: { showEditForm = true }) {
                        Label("Edit Layer", systemImage: "pencil")
                    }
                    Button(action: { layer.isFavorite.toggle() }) {
                        Label(
                            layer.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: layer.isFavorite ? "star.slash" : "star.fill"
                        )
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
        .sheet(isPresented: $showAddWaypoint) {
            WaypointFormView(layer: layer)
        }
    }

    private func removePlaces(at offsets: IndexSet) {
        let sorted = layerPlaces
        for index in offsets {
            let place = sorted[index]
            layer.places?.removeAll { $0.id == place.id }
            // For waypoint-path layers, points exist only inside the layer — also delete the Place.
            if isWaypointPath, (place.layers?.isEmpty ?? true) {
                modelContext.delete(place)
            }
        }
    }
}

struct WaypointRowView: View {
    @Bindable var place: Place

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name.isEmpty ? "Waypoint" : place.name)
                    .font(.body)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $place.isWaypointEndpoint) {
                Label("Start/End", systemImage: place.isWaypointEndpoint ? "flag.fill" : "flag")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .tint(.orange)
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
