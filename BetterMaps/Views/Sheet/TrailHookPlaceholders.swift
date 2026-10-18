import SwiftUI

// TRAIL HOOK placeholders. MapScreen presents these for
// `ActiveSheet.trailDetail(id)` and `MapViewModel.drawTrailRequest` until
// the Trails views (Views/Trails/*) are wired in. Replace, don't extend.

/// TODO(trails): replace with the trail detail view for `trailId`.
struct TrailDetailPlaceholder: View {
    let trailId: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Trail details")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Trail")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// TODO(trails): replace with the trail editor for `request`.
struct DrawTrailPlaceholder: View {
    let request: DrawTrailRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Trail drawing")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Draw trail")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
        }
    }
}
