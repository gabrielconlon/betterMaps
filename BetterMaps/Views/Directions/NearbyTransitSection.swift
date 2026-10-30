import SwiftUI
import CoreLocation

/// "Nearby transit" on a place card: the closest stops with their distance
/// and the routes serving them (or the networks, when the timetable is not
/// downloaded). Tapping a stop opens its arrivals in place of this card.
/// Renders nothing while loading or when no stop is within reach.
struct NearbyTransitSection: View {
    let coordinate: CLLocationCoordinate2D
    let onOpenStop: (TransitStop) -> Void

    @State private var nearby: [NearbyTransit] = []

    private static let shown = 5

    var body: some View {
        Group {
            if !nearby.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nearby transit")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    ForEach(nearby.prefix(Self.shown), id: \.stop.id) { item in
                        row(item)
                    }
                }
            }
        }
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            let store = TransitLayerStore.shared
            await store.loadIfNeeded()
            guard !Task.isCancelled else { return }
            let found = await NearbyTransitService().nearby(coordinate, grid: store.grid)
            guard !Task.isCancelled else { return }
            nearby = found
        }
    }

    private func row(_ item: NearbyTransit) -> some View {
        Button { onOpenStop(item.stop) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.stop.kind.systemImage)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(TransitColors.pin(for: item.stop), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.stop.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(DirectionsFormat.distance(item.distanceMeters))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    chips(item)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityHint("Shows arrivals at this stop")
    }

    @ViewBuilder
    private func chips(_ item: NearbyTransit) -> some View {
        if item.routesKnown, !item.routes.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(item.routes) { route in
                    Text(TransitArrivalsView.routeLabel(route.short))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(TransitColors.pin(for: route), in: Capsule())
                }
            }
        } else {
            Text(networks(item.stop))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Luas Red line" / "DART, Rail" / "Bus · Stop 1234".
    private func networks(_ stop: TransitStop) -> String {
        if stop.kind == .luas, let line = stop.line {
            return "Luas \(line.capitalized) line"
        }
        let names = stop.kinds.map(\.displayName).joined(separator: ", ")
        if let code = stop.code, stop.kind == .bus { return "\(names) · Stop \(code)" }
        return names
    }

    private func accessibilityLabel(_ item: NearbyTransit) -> String {
        var text = "\(item.stop.name), \(DirectionsFormat.distance(item.distanceMeters)) away"
        if item.routesKnown, !item.routes.isEmpty {
            text += ", routes \(item.routes.map { TransitArrivalsView.routeLabel($0.short) }.joined(separator: ", "))"
        } else {
            text += ", \(networks(item.stop))"
        }
        return text
    }
}
