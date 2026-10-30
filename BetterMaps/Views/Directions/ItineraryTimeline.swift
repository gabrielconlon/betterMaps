import SwiftUI

/// The picked option leg by leg: a coloured bar per leg, where it starts and
/// ends with times, the route and headsign, and the stops passed (folded).
struct ItineraryTimeline: View {
    let itinerary: Itinerary
    /// Catalyst only: the sheet covers the map there, so a row offers to
    /// close it and look at the drawn journey.
    var onShowOnMap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if targetEnvironment(macCatalyst)
            if let onShowOnMap {
                Button(action: onShowOnMap) {
                    Label("Show on map", systemImage: "map")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Divider()
            }
            #endif
            ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                LegRow(leg: leg, isLast: index == itinerary.legs.count - 1)
            }
        }
    }
}

private struct LegRow: View {
    let leg: Leg
    let isLast: Bool
    @State private var showsStops = false

    private var color: Color { TransitColors.leg(for: leg) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Rail: a bar in the leg colour (dashed for walking) with the
            // mode icon at its head.
            VStack(spacing: 0) {
                Image(systemName: leg.mode.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(color, in: Circle())
                bar
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(leg.fromName)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(DirectionsFormat.clock(leg.start))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if leg.isRealtime { LiveBadge() }
                }
                if leg.mode.isTransit, !leg.intermediateStops.isEmpty {
                    DisclosureGroup(isExpanded: $showsStops) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(leg.intermediateStops.enumerated()), id: \.offset) { _, stop in
                                HStack {
                                    Text(stop.name)
                                    Spacer(minLength: 8)
                                    Text(DirectionsFormat.clock(stop.time)).monospacedDigit()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text(DirectionsFormat.stopCount(leg.intermediateStops.count))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                }
                if isLast {
                    HStack(alignment: .firstTextBaseline) {
                        Label(leg.toName, systemImage: "flag.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(DirectionsFormat.clock(leg.end))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Luas Red towards The Point · 13 min" / "Walk 3 min".
    private var description: String {
        var text = DirectionsFormat.legName(leg)
        if leg.mode.isTransit, let headsign = leg.headsign, !headsign.isEmpty {
            text += " towards \(headsign)"
        }
        return "\(text) · \(DirectionsFormat.minutes(leg.durationSeconds))"
    }

    @ViewBuilder
    private var bar: some View {
        if !isLast {
            if leg.mode == .walk {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        GeometryReader { geo in
                            Path { path in
                                path.move(to: CGPoint(x: 2, y: 0))
                                path.addLine(to: CGPoint(x: 2, y: geo.size.height))
                            }
                            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [5, 5]))
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}
