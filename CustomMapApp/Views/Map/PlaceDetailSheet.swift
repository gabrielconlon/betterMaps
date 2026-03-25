import SwiftUI
import SwiftData

struct PlaceDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var place: Place
    let onGetDirections: (Place) -> Void
    let onEdit: (Place) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name)
                            .font(.title2.bold())

                        if place.rating > 0 {
                            RatingDisplayView(rating: place.rating)
                        }
                    }

                    Spacer()

                    Button(action: { onGetDirections(place) }) {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Tags
                if !place.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(place.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.blue.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Hours
                if !place.hoursInfo.isEmpty {
                    Label(place.hoursInfo, systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Notes
                if !place.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Text(place.notes)
                            .font(.body)
                    }
                }

                // Layers
                if let layers = place.layers, !layers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Layers")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ForEach(layers) { layer in
                            HStack(spacing: 8) {
                                Image(systemName: layer.symbolName)
                                    .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                                Text(layer.name)
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                // Photos
                if !place.photoData.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Photos")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(place.photoData.indices, id: \.self) { index in
                                    if let uiImage = UIImage(data: place.photoData[index]) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 120, height: 90)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    }
                }

                // Edit button
                Button(action: { onEdit(place) }) {
                    Label("Edit Place", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}
