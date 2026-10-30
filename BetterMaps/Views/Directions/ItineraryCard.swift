import SwiftUI

/// One option in the results list: the duration first (what people compare
/// on), then the walk/changes summary, the time range and the leg chips.
struct ItineraryCard: View {
    let itinerary: Itinerary
    /// Position in the list, for the accessibility identifier.
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DirectionsFormat.minutes(itinerary.durationSeconds))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(DirectionsFormat.timeRange(itinerary.start, itinerary.end))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(DirectionsFormat.summary(walkSeconds: itinerary.walkSeconds,
                                                  bikeSeconds: itinerary.bikeSeconds,
                                                  transfers: itinerary.transfers))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let reason = itinerary.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if itinerary.legs.contains(where: \.isRealtime) {
                        LiveBadge()
                    }
                }
                ModeChipStrip(legs: itinerary.legs)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("directions.itinerary.\(index)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows this journey on the map")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "48 minutes, leaves 10:05, arrives 10:53, walk 9 min · 1 change, via Luas Red, DART."
    private var accessibilityLabel: String {
        let modes = itinerary.transitLegs.map(DirectionsFormat.legName)
        var sentence = "\(DirectionsFormat.minutes(itinerary.durationSeconds).replacingOccurrences(of: " min", with: " minutes"))"
        sentence += ", leaves \(DirectionsFormat.clock(itinerary.start)), arrives \(DirectionsFormat.clock(itinerary.end))"
        sentence += ", \(DirectionsFormat.summary(walkSeconds: itinerary.walkSeconds, bikeSeconds: itinerary.bikeSeconds, transfers: itinerary.transfers))"
        if !modes.isEmpty { sentence += ", via \(modes.joined(separator: ", "))" }
        return sentence + "."
    }
}

/// Green "Live" pill, as on the arrivals board.
struct LiveBadge: View {
    var body: some View {
        Text("Live")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.18))
            .foregroundStyle(Color.green)
            .clipShape(Capsule())
    }
}
