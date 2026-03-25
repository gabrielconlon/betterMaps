import SwiftUI

struct RoutingPanelView: View {
    let viewModel: RoutingViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding routes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView(
                        "No Routes",
                        systemImage: "map.fill",
                        description: Text(error)
                    )
                } else if viewModel.activeRoutes.isEmpty {
                    ContentUnavailableView(
                        "No Routes",
                        systemImage: "map.fill",
                        description: Text("No routes available for this destination.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(viewModel.activeRoutes) { result in
                                RouteResultCard(result: result)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
