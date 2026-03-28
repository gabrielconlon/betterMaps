import SwiftUI
import SwiftData
import MapKit

struct PlaceFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let place: Place?
    let initialCoordinate: CLLocationCoordinate2D?
    let targetLayer: Layer?

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var rating: Int = 0
    @State private var hoursInfo: String = ""
    @State private var tagsText: String = ""
    @State private var latitude: Double = 37.7749
    @State private var longitude: Double = -122.4194
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var photoData: [Data] = []

    var isEditing: Bool { place != nil }

    init(place: Place? = nil, coordinate: CLLocationCoordinate2D? = nil, layer: Layer? = nil) {
        self.place = place
        self.initialCoordinate = coordinate
        self.targetLayer = layer
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Place name", text: $name)
                }

                Section("Location") {
                    Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                        Marker(name.isEmpty ? "New Place" : name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                    HStack {
                        Text("Lat")
                            .foregroundStyle(.secondary)
                        TextField("Latitude", value: $latitude, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Lng")
                            .foregroundStyle(.secondary)
                        TextField("Longitude", value: $longitude, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Rating") {
                    RatingView(rating: $rating)
                }

                Section("Details") {
                    TextField("Hours (e.g., Mon-Fri 9-5)", text: $hoursInfo)
                    TextField("Tags (comma separated)", text: $tagsText)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                Section("Photos") {
                    PhotoPickerView(photoData: $photoData)
                }
            }
            .navigationTitle(isEditing ? "Edit Place" : "New Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let place {
                    name = place.name
                    notes = place.notes
                    rating = place.rating
                    hoursInfo = place.hoursInfo
                    tagsText = place.tags.joined(separator: ", ")
                    latitude = place.latitude
                    longitude = place.longitude
                    photoData = place.photoData
                } else if let coord = initialCoordinate {
                    latitude = coord.latitude
                    longitude = coord.longitude
                }
                cameraPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let parsedTags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let place {
            place.name = trimmedName
            place.notes = notes
            place.rating = rating
            place.hoursInfo = hoursInfo
            place.tags = parsedTags
            place.latitude = latitude
            place.longitude = longitude
            place.photoData = photoData
            place.updatedAt = Date()
        } else {
            let newPlace = Place(
                name: trimmedName,
                latitude: latitude,
                longitude: longitude,
                notes: notes,
                rating: rating,
                hoursInfo: hoursInfo,
                tags: parsedTags
            )
            newPlace.photoData = photoData
            modelContext.insert(newPlace)

            if let targetLayer {
                if targetLayer.places == nil {
                    targetLayer.places = []
                }
                targetLayer.places?.append(newPlace)
            }
        }
        dismiss()
    }
}
