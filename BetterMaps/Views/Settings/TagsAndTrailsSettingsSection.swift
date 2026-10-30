import SwiftUI
import SwiftData

/// Settings → "Tags and trails": create, edit and delete tags and trail
/// groups. This used to sit at the bottom of the map sheet as "New tag" /
/// "New trail group" rows, which pushed pinned routes and stops below the
/// fold; the sheet now only browses them.
struct TagsAndTrailsSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]

    @State private var editing: EditTarget?
    @State private var pendingDelete: Layer?

    /// What the form sheet edits: an existing layer, or a new one of a kind.
    private enum EditTarget: Identifiable {
        case existing(Layer)
        case new(LayerKind)

        var id: String {
            switch self {
            case .existing(let layer): return layer.id.uuidString
            case .new(let kind): return "new-\(kind.rawValue)"
            }
        }
    }

    private var tags: [Layer] { layers.filter { $0.kind == .places } }
    private var trailGroups: [Layer] { layers.filter { $0.kind == .waypointPath } }

    var body: some View {
        Section {
            ForEach(tags) { row(for: $0) }
            Button { editing = .new(.places) } label: {
                Label("New tag", systemImage: "plus")
            }
        } header: {
            Text("Tags")
        }
        Section {
            ForEach(trailGroups) { row(for: $0) }
            Button { editing = .new(.waypointPath) } label: {
                Label("New trail group", systemImage: "plus")
            }
        } header: {
            Text("Trail groups")
        } footer: {
            Text("Tap to rename or restyle. Swipe left to delete.")
        }
        .sheet(item: $editing) { target in
            switch target {
            case .existing(let layer): LayerFormView(layer: layer)
            case .new(let kind): LayerFormView(layer: nil, kind: kind)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete,
                            titleVisibility: .visible, presenting: pendingDelete) { layer in
            Button(layer.kind == .waypointPath ? "Delete trail group" : "Delete tag", role: .destructive) {
                PlaceCleanup.deleteLayer(layer, in: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: { layer in
            Text(layer.kind == .waypointPath
                 ? "Its trails and their points are deleted too. This can't be undone."
                 : "Places with only this tag will be deleted. Places with other tags keep them. This can't be undone.")
        }
    }

    private func row(for layer: Layer) -> some View {
        let isTrailGroup = layer.kind == .waypointPath
        return Button { editing = .existing(layer) } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(hex: layer.colorHex) ?? .red)
                    Image(systemName: isTrailGroup ? LayerKind.waypointPath.systemImage : layer.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                Text(layer.name)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(summary(for: layer))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityHint(isTrailGroup ? "Edits the trail group" : "Edits the tag")
        .swipeActions {
            Button(role: .destructive) { pendingDelete = layer } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func summary(for layer: Layer) -> String {
        if layer.kind == .waypointPath {
            let count = layer.trails?.count ?? 0
            return count == 1 ? "1 trail" : "\(count) trails"
        }
        let count = layer.places?.count ?? 0
        return count == 1 ? "1 place" : "\(count) places"
    }

    private var deleteTitle: String {
        "Delete “\(pendingDelete?.name ?? "tag")”?"
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}
