import SwiftUI
import SwiftData
import MapKit

/// Lightweight form for adding a waypoint into a waypoint-path layer.
/// Waypoints are Place models like any other but are usually unnamed and only carry a coordinate.
struct WaypointFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let layer: Layer

    @State private var name: String = ""
    @State private var latitude: Double = 53.3498
    @State private var longitude: Double = -6.2603
    @State private var isEndpoint: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Form {
                Section("Name (optional)") {
                    TextField("e.g. Trailhead", text: $name)
                }

                Section("Location") {
                    Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                        Marker(name.isEmpty ? "Waypoint" : name,
                               coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                    HStack {
                        Text("Lat").foregroundStyle(.secondary)
                        TextField("Latitude", value: $latitude, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Lng").foregroundStyle(.secondary)
                        TextField("Longitude", value: $longitude, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Toggle(isOn: $isEndpoint) {
                        Label("Start / End of path", systemImage: "flag.fill")
                    }
                } footer: {
                    Text("Endpoints connect to only their single nearest neighbor.")
                }
            }
            .navigationTitle("New Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                }
            }
            .onAppear {
                // Seed the camera at an existing waypoint in this layer if there is one.
                if let existing = layer.places?.first {
                    latitude = existing.latitude
                    longitude = existing.longitude
                }
                cameraPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let waypoint = Place(
            name: trimmed.isEmpty ? "Waypoint" : trimmed,
            latitude: latitude,
            longitude: longitude
        )
        waypoint.isWaypointEndpoint = isEndpoint
        modelContext.insert(waypoint)
        if layer.places == nil { layer.places = [] }
        layer.places?.append(waypoint)
        dismiss()
    }
}
