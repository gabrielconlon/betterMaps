import SwiftUI
import SwiftData

struct LayersTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @State private var showNewLayerForm = false

    var body: some View {
        NavigationStack {
            Group {
                if layers.isEmpty {
                    ContentUnavailableView(
                        "No Layers",
                        systemImage: "square.3.layers.3d",
                        description: Text("Create your first layer to start organizing places.")
                    )
                } else {
                    List {
                        ForEach(layers) { layer in
                            NavigationLink(destination: LayerDetailView(layer: layer)) {
                                LayerRowView(layer: layer)
                            }
                        }
                        .onDelete(perform: deleteLayers)
                    }
                }
            }
            .navigationTitle("Layers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showNewLayerForm = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewLayerForm) {
                LayerFormView(layer: nil)
            }
        }
    }

    private func deleteLayers(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(layers[index])
        }
    }
}

struct LayerRowView: View {
    let layer: Layer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: layer.symbolName)
                .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.body)
                Text("\(layer.places?.count ?? 0) places")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(layer.isVisible ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }
}
