import SwiftUI
import SwiftData
import CoreLocation

struct RoutingPanelView: View {
    @Environment(\.modelContext) private var modelContext
    let viewModel: RoutingViewModel
    var originName: String = "Current Location"
    var destinationName: String = ""
    var source: CLLocationCoordinate2D?
    var destination: CLLocationCoordinate2D?

    @Binding var selectedRouteId: UUID?
    @State private var saved = false
    @State private var selectedRoute: RouteResult?
    @State private var selectedTransitOption: TransitRouteOption?

    var body: some View {
        NavigationStack {
            Group {
                if let transitOption = selectedTransitOption {
                    TransitTimelineView(option: transitOption)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: { selectedTransitOption = nil }) {
                                    Label("Routes", systemImage: "chevron.left")
                                }
                            }
                        }
                } else if let route = selectedRoute {
                    // Step-by-step view replaces the route list
                    NavigationStepsView(
                        routeResult: route,
                        destinationCoordinate: destination,
                        destinationName: destinationName
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: {
                                selectedRoute = nil
                                selectedRouteId = nil
                            }) {
                                Label("Routes", systemImage: "chevron.left")
                            }
                        }
                    }
                    .onAppear { selectedRouteId = route.id }
                } else {
                    routeListView
                }
            }
        }
    }

    private var routeListView: some View {
        ScrollView {
            VStack(spacing: 8) {
                if viewModel.isLoading && viewModel.activeRoutes.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding routes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                ForEach(viewModel.activeRoutes) { result in
                    RouteResultCard(result: result, onSelect: {
                        selectedRoute = result
                    })
                }

                if viewModel.isLoading && !viewModel.activeRoutes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading more routes...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                // Transit options (multi-modal: walk → bus/tram → walk)
                if !viewModel.transitOptions.isEmpty || viewModel.isLoadingTransit || viewModel.transitStatusMessage != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "tram.fill")
                                .foregroundStyle(.green)
                            Text("Transit Options")
                                .font(.subheadline.bold())
                            if viewModel.isLoadingTransit {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if let status = viewModel.transitStatusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(viewModel.transitOptions) { option in
                            TransitOptionCard(option: option, onSelect: {
                                selectedTransitOption = option
                            })
                        }

                        if viewModel.transitOptions.isEmpty && !viewModel.isLoadingTransit {
                            Text("No transit routes found for this trip.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                // Failed routes
                if !viewModel.failedModes.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(viewModel.failedModes.keys), id: \.self) { mode in
                            HStack(spacing: 8) {
                                Image(systemName: mode.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(mode.displayName) unavailable")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.failedModes[mode] ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.top, 4)
                }

                // Save for offline
                if !viewModel.activeRoutes.isEmpty && !viewModel.isLoading {
                    Button(action: saveOffline) {
                        Label(
                            saved ? "Saved for offline!" : "Save for offline",
                            systemImage: saved ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(saved ? .green : .blue)
                    .disabled(saved)
                    .padding(.top, 4)
                }

                if !viewModel.isLoading && viewModel.activeRoutes.isEmpty {
                    ContentUnavailableView(
                        "No Routes",
                        systemImage: "map.fill",
                        description: Text(viewModel.errorMessage ?? "No routes available.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Routes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveOffline() {
        guard let source, let destination else { return }
        viewModel.saveCurrentRoutes(
            context: modelContext,
            originName: originName,
            destinationName: destinationName,
            source: source,
            destination: destination
        )
        saved = true
    }
}
