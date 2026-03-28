import SwiftUI
import MapKit

// MARK: - Transit Option Card (compact summary for route list)

struct TransitOptionCard: View {
    let option: TransitRouteOption
    var onSelect: (() -> Void)?

    var body: some View {
        Button(action: { onSelect?() }) {
            HStack(spacing: 12) {
                // Mode icons summary
                modeIconsStrip

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.summary)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(formattedDuration(option.totalDuration))
                            .font(.subheadline.bold())

                        if option.transfers > 0 {
                            Text("\(option.transfers) transfer\(option.transfers == 1 ? "" : "s")")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 4) {
                        Text("Departs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formattedTime(option.departureTime))
                            .font(.caption.bold())
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("Arrives")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formattedTime(option.arrivalTime))
                            .font(.caption.bold())
                    }

                    if option.totalWalkingMinutes > 0 {
                        Label("\(option.totalWalkingMinutes) min walking", systemImage: "figure.walk")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mode Icons Strip

    private var modeIconsStrip: some View {
        VStack(spacing: 4) {
            ForEach(uniqueModes, id: \.self) { mode in
                Image(systemName: iconName(for: mode))
                    .font(.caption)
                    .foregroundStyle(color(for: mode))
                    .frame(width: 24, height: 24)
                    .background(color(for: mode).opacity(0.12))
                    .clipShape(Circle())
            }
        }
    }

    private var uniqueModes: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for leg in option.legs {
            let key: String
            switch leg {
            case .walk:
                key = "walk"
            case .ride(_, _, _, _, _, _, _, _, let mode, _, _, _):
                key = mode.rawValue
            case .transfer:
                continue
            }
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }

    // MARK: - Formatting

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours) hr" : "\(hours)h \(rem)m"
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Transit Timeline View (full leg-by-leg)

struct TransitTimelineView: View {
    let option: TransitRouteOption
    var destinationCoordinate: CLLocationCoordinate2D?
    var destinationName: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                headerSection

                // Timeline legs
                ForEach(Array(option.legs.enumerated()), id: \.element.id) { index, leg in
                    timelineLegRow(
                        leg: leg,
                        isFirst: index == 0,
                        isLast: index == option.legs.count - 1
                    )
                }

                // Summary bar
                summaryBar

                // Open in Apple Maps
                openInMapsButton
            }
            .padding()
        }
        .navigationTitle("Transit Route")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(option.summary)
                .font(.title3.bold())

            HStack(spacing: 12) {
                Label(formattedDuration(option.totalDuration), systemImage: "clock")
                    .font(.subheadline)

                if option.transfers > 0 {
                    Label(
                        "\(option.transfers) transfer\(option.transfers == 1 ? "" : "s")",
                        systemImage: "arrow.triangle.swap"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }

                Label(
                    "\(option.totalWalkingMinutes) min walk",
                    systemImage: "figure.walk"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.top, 8)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Timeline Leg Row

    @ViewBuilder
    private func timelineLegRow(leg: TransitLeg, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline connector
            timelineConnector(leg: leg, isFirst: isFirst, isLast: isLast)

            // Leg content
            legContent(leg: leg)
                .padding(.bottom, 16)
        }
    }

    private func timelineConnector(leg: TransitLeg, isFirst: Bool, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            // Top line
            if !isFirst {
                Rectangle()
                    .fill(connectorColor(for: leg).opacity(0.4))
                    .frame(width: 2, height: 8)
            } else {
                Spacer()
                    .frame(width: 2, height: 8)
            }

            // Circle node
            ZStack {
                Circle()
                    .fill(legColor(for: leg).opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: legIcon(for: leg))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(legColor(for: leg))
            }

            // Bottom line
            if !isLast {
                Rectangle()
                    .fill(connectorColor(for: leg).opacity(0.4))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer()
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 32)
    }

    @ViewBuilder
    private func legContent(leg: TransitLeg) -> some View {
        switch leg {
        case .walk(_, let durationMinutes, let distance, let from, let to, _, _):
            walkLegContent(
                durationMinutes: durationMinutes,
                distance: distance,
                from: from,
                to: to
            )

        case .ride(_, let routeName, let routeLongName, let boardStop, let alightStop,
                   let departureTime, let arrivalTime, let numStops, let mode, _, _, _):
            rideLegContent(
                routeName: routeName,
                routeLongName: routeLongName,
                boardStop: boardStop,
                alightStop: alightStop,
                departureTime: departureTime,
                arrivalTime: arrivalTime,
                numStops: numStops,
                mode: mode
            )

        case .transfer(_, let walkMinutes, let fromStop, let toStop, _, _):
            transferLegContent(
                walkMinutes: walkMinutes,
                fromStop: fromStop,
                toStop: toStop
            )
        }
    }

    // MARK: - Walk Leg

    private func walkLegContent(
        durationMinutes: Int,
        distance: Double,
        from: String,
        to: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Walk \(durationMinutes) min")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

            if !from.isEmpty && !to.isEmpty {
                Text("\(from) to \(to)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !to.isEmpty {
                Text("to \(to)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if distance > 0 {
                Text(formattedDistance(distance))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Ride Leg

    private func rideLegContent(
        routeName: String,
        routeLongName: String = "",
        boardStop: String,
        alightStop: String,
        departureTime: String,
        arrivalTime: String,
        numStops: Int,
        mode: TransitLegMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(routeName)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color(for: mode.rawValue).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(alightStop)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            if !routeLongName.isEmpty {
                Text(routeLongName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                if numStops > 0 {
                    Text("\(numStops) stop\(numStops == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Board")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(departureTime)
                        .font(.caption.bold())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Alight")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(arrivalTime)
                        .font(.caption.bold())
                }

                Spacer()
            }

            Text(boardStop)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: mode.rawValue).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Transfer Leg

    private func transferLegContent(
        walkMinutes: Int,
        fromStop: String,
        toStop: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Transfer")
                    .font(.subheadline.bold())
                Text("· Walk \(walkMinutes) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !fromStop.isEmpty && !toStop.isEmpty {
                Text("\(fromStop) to \(toStop)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: 16) {
            Label(formattedDuration(option.totalDuration), systemImage: "clock.fill")
                .font(.subheadline.bold())

            if option.transfers > 0 {
                Label(
                    "\(option.transfers) transfer\(option.transfers == 1 ? "" : "s")",
                    systemImage: "arrow.triangle.swap"
                )
                .font(.subheadline)
            }

            Label(
                "Departs \(formattedTime(option.departureTime))",
                systemImage: "calendar.badge.clock"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
    }

    // MARK: - Open in Apple Maps

    private var openInMapsButton: some View {
        Button(action: openInAppleMaps) {
            Label("Open in Apple Maps", systemImage: "arrow.up.forward.app")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .padding(.top, 12)
    }

    private func openInAppleMaps() {
        guard let coord = destinationCoordinate else { return }
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = destinationName ?? "Destination"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit
        ])
    }

    // MARK: - Helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours) hr" : "\(hours)h \(rem)m"
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formattedDistance(_ meters: Double) -> String {
        if meters < 100 {
            return "\(Int(meters)) m"
        }
        return String(format: "%.1f km", meters / 1000.0)
    }
}

// MARK: - Shared Color & Icon Helpers

private func legColor(for leg: TransitLeg) -> Color {
    switch leg {
    case .walk:
        return .green
    case .ride(_, _, _, _, _, _, _, _, let mode, _, _, _):
        return color(for: mode.rawValue)
    case .transfer:
        return .green
    }
}

private func legIcon(for leg: TransitLeg) -> String {
    switch leg {
    case .walk:
        return "figure.walk"
    case .ride(_, _, _, _, _, _, _, _, let mode, _, _, _):
        return iconName(for: mode.rawValue)
    case .transfer:
        return "figure.walk"
    }
}

private func connectorColor(for leg: TransitLeg) -> Color {
    switch leg {
    case .walk:
        return .green
    case .ride(_, _, _, _, _, _, _, _, let mode, _, _, _):
        return color(for: mode.rawValue)
    case .transfer:
        return .gray
    }
}

private func iconName(for modeKey: String) -> String {
    switch modeKey {
    case "bus":
        return "bus.fill"
    case "luas":
        return "tram.fill"
    case "dart":
        return "tram.fill"
    case "rail":
        return "tram.fill"
    case "walk":
        return "figure.walk"
    default:
        return "bus.fill"
    }
}

private func color(for modeKey: String) -> Color {
    switch modeKey {
    case "bus":
        return .blue
    case "luas":
        return .green
    case "dart":
        return .orange
    case "rail":
        return .purple
    case "walk":
        return .green
    default:
        return .gray
    }
}

// MARK: - Preview

#Preview("Timeline") {
    let dublin = LegCoordinate(latitude: 53.35, longitude: -6.26)
    NavigationStack {
        TransitTimelineView(
            option: TransitRouteOption(
                id: UUID(),
                legs: [
                    .walk(id: UUID(), durationMinutes: 5, distance: 350, from: "", to: "Cabra Stop",
                          fromCoord: dublin, toCoord: dublin),
                    .ride(id: UUID(), routeName: "39A", routeId: "39A", boardStop: "Cabra Stop",
                          alightStop: "City Centre", departureTime: "12:05",
                          arrivalTime: "12:23", numStops: 12, mode: .bus,
                          boardCoord: dublin, alightCoord: dublin, pathCoords: [dublin]),
                    .transfer(id: UUID(), walkMinutes: 2, fromStop: "Abbey St", toStop: "Abbey St Luas",
                              fromCoord: dublin, toCoord: dublin),
                    .ride(id: UUID(), routeName: "Luas Green", routeId: "LUAS_GREEN",
                          boardStop: "Abbey St", alightStop: "Bride's Glen",
                          departureTime: "12:28", arrivalTime: "12:42", numStops: 8, mode: .luas,
                          boardCoord: dublin, alightCoord: dublin, pathCoords: [dublin]),
                    .walk(id: UUID(), durationMinutes: 3, distance: 200, from: "Bride's Glen", to: "Destination",
                          fromCoord: dublin, toCoord: dublin),
                ],
                totalDuration: 2520,
                totalWalkingMinutes: 10,
                departureTime: Date(),
                arrivalTime: Date().addingTimeInterval(2520),
                transfers: 2,
                summary: "39A → Luas Green"
            )
        )
    }
}

#Preview("Option Card") {
    let dublin = LegCoordinate(latitude: 53.35, longitude: -6.26)
    TransitOptionCard(
        option: TransitRouteOption(
            id: UUID(),
            legs: [
                .walk(id: UUID(), durationMinutes: 5, distance: 350, from: "", to: "Cabra Stop",
                      fromCoord: dublin, toCoord: dublin),
                .ride(id: UUID(), routeName: "39A", routeId: "39A", boardStop: "Cabra Stop",
                      alightStop: "City Centre", departureTime: "12:05",
                      arrivalTime: "12:23", numStops: 12, mode: .bus,
                      boardCoord: dublin, alightCoord: dublin, pathCoords: [dublin]),
                .ride(id: UUID(), routeName: "Luas Green", routeId: "LUAS_GREEN",
                      boardStop: "Abbey St", alightStop: "Bride's Glen",
                      departureTime: "12:28", arrivalTime: "12:42", numStops: 8, mode: .luas,
                      boardCoord: dublin, alightCoord: dublin, pathCoords: [dublin]),
            ],
            totalDuration: 2520,
            totalWalkingMinutes: 10,
            departureTime: Date(),
            arrivalTime: Date().addingTimeInterval(2520),
            transfers: 1,
            summary: "39A → Luas Green"
        )
    )
    .padding()
}
