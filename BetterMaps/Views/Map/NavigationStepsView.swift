import SwiftUI
import MapKit

struct NavigationStepsView: View {
    let routeResult: RouteResult
    var destinationCoordinate: CLLocationCoordinate2D?
    var destinationName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var currentStepIndex = 0

    var steps: [NavigationStep] {
        // MapKit route steps (driving, walking, transit)
        if let route = routeResult.route {
            return route.steps.enumerated().map { index, step in
                NavigationStep(
                    index: index,
                    instruction: step.instructions.isEmpty ? "Continue" : step.instructions,
                    distance: step.distance,
                    isFirst: index == 0,
                    isLast: index == route.steps.count - 1
                )
            }
        }
        // ORS cycling steps
        if !routeResult.cyclingSteps.isEmpty {
            return routeResult.cyclingSteps.enumerated().map { index, step in
                NavigationStep(
                    index: index,
                    instruction: step.instruction,
                    distance: step.distance,
                    isFirst: index == 0,
                    isLast: index == routeResult.cyclingSteps.count - 1
                )
            }
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
                // Current step highlight
                if !steps.isEmpty && currentStepIndex < steps.count {
                    let step = steps[currentStepIndex]
                    VStack(spacing: 8) {
                        Image(systemName: directionIcon(for: step.instruction))
                            .font(.system(size: 40))
                            .foregroundStyle(routeResult.mode.color)

                        Text(step.instruction)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)

                        if step.distance > 0 {
                            Text(formattedDistance(step.distance))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(routeResult.mode.color.opacity(0.08))

                    // Prev / Next buttons
                    HStack {
                        Button(action: { currentStepIndex = max(0, currentStepIndex - 1) }) {
                            Label("Previous", systemImage: "chevron.left")
                        }
                        .disabled(currentStepIndex == 0)

                        Spacer()

                        Text("Step \(currentStepIndex + 1) of \(steps.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(action: { currentStepIndex = min(steps.count - 1, currentStepIndex + 1) }) {
                            Label("Next", systemImage: "chevron.right")
                        }
                        .disabled(currentStepIndex >= steps.count - 1)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Full step list
                List {
                    Section("Route Summary") {
                        HStack {
                            Image(systemName: routeResult.mode.systemImage)
                                .foregroundStyle(routeResult.mode.color)
                            Text(routeResult.mode.displayName)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(formattedDuration(routeResult.eta))
                                .font(.subheadline)
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(formattedDistance(routeResult.distance))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Open in Apple Maps
                    Section {
                        Button(action: openInAppleMaps) {
                            Label("Open in Apple Maps", systemImage: "arrow.up.forward.app")
                        }
                    }

                    if steps.isEmpty {
                        Section {
                            Text("Turn-by-turn steps are available for driving, walking, and transit routes. Cycling routes show the route on the map.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Directions") {
                            ForEach(steps) { step in
                                Button(action: { currentStepIndex = step.index }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: directionIcon(for: step.instruction))
                                            .foregroundStyle(currentStepIndex == step.index ? routeResult.mode.color : .secondary)
                                            .frame(width: 24)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(step.instruction)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            if step.distance > 0 {
                                                Text(formattedDistance(step.distance))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .listRowBackground(
                                    currentStepIndex == step.index
                                        ? routeResult.mode.color.opacity(0.08)
                                        : Color.clear
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func openInAppleMaps() {
        guard let coord = destinationCoordinate else { return }
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = destinationName ?? "Destination"

        let launchOptions: [String: Any]
        switch routeResult.mode {
        case .driving:
            launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        case .walking:
            launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        case .transit:
            launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit]
        case .cycling:
            // Apple Maps doesn't have cycling mode — default to walking
            launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        }
        mapItem.openInMaps(launchOptions: launchOptions)
    }

    private func directionIcon(for instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("left") { return "arrow.turn.up.left" }
        if lower.contains("right") { return "arrow.turn.up.right" }
        if lower.contains("u-turn") || lower.contains("u turn") { return "arrow.uturn.down" }
        if lower.contains("arrive") || lower.contains("destination") { return "mappin.circle.fill" }
        if lower.contains("depart") || lower.contains("start") || lower.contains("head") { return "location.fill" }
        if lower.contains("roundabout") || lower.contains("rotary") { return "arrow.triangle.2.circlepath" }
        if lower.contains("merge") { return "arrow.merge" }
        if lower.contains("exit") { return "arrow.up.right" }
        if lower.contains("straight") || lower.contains("continue") { return "arrow.up" }
        return "arrow.up"
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        if mins < 60 { return "\(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem == 0 ? "\(hrs) hr" : "\(hrs)h \(rem)m"
    }

    private func formattedDistance(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles < 0.1 { return "\(Int(meters * 3.28084)) ft" }
        return String(format: "%.1f mi", miles)
    }
}

struct NavigationStep: Identifiable {
    let index: Int
    let instruction: String
    let distance: CLLocationDistance
    let isFirst: Bool
    let isLast: Bool

    var id: Int { index }
}
