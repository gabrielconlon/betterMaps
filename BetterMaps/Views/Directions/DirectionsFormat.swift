import Foundation

/// Shared copy for the directions sheet: durations, chip labels, summaries.
enum DirectionsFormat {
    /// "42 min" / "1 h 05 min"; anything under a minute reads "1 min".
    static func minutes(_ seconds: Int) -> String {
        let total = max(1, Int((Double(max(seconds, 0)) / 60).rounded()))
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        return String(format: "%d h %02d min", hours, rest)
    }

    /// Chip text for one leg: "Walk 3", "Luas Red 13", "DART 26", "Bus 39A 12".
    static func chipLabel(_ leg: Leg) -> String {
        "\(legName(leg)) \(wholeMinutes(leg.durationSeconds))"
    }

    /// "Luas Red", "DART", "Bus 39A", "Walk": the leg without its duration.
    static func legName(_ leg: Leg) -> String {
        let mode = leg.mode.displayName
        guard leg.mode.isTransit, let short = leg.routeShortName?.trimmingCharacters(in: .whitespaces),
              !short.isEmpty, short.caseInsensitiveCompare(mode) != .orderedSame else {
            return mode
        }
        return "\(mode) \(TransitArrivalsView.routeLabel(short))"
    }

    /// "walk 9 min · 1 change" / "walk 9 min · no changes" / "No changes".
    static func summary(walkSeconds: Int, bikeSeconds: Int, transfers: Int) -> String {
        var parts: [String] = []
        if walkSeconds >= 30 { parts.append("walk \(minutes(walkSeconds))") }
        if bikeSeconds >= 30 { parts.append("bike \(minutes(bikeSeconds))") }
        let changes: String
        switch transfers {
        case ..<1: changes = "no changes"
        case 1: changes = "1 change"
        default: changes = "\(transfers) changes"
        }
        guard !parts.isEmpty else { return changes.prefix(1).uppercased() + changes.dropFirst() }
        parts.append(changes)
        return parts.joined(separator: " · ")
    }

    /// "10:05 – 10:47" in the user's clock style.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(clock(start)) – \(clock(end))"
    }

    /// "10:05" in the user's clock style.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "240 m" (to the nearest 10 m) / "1.2 km".
    static func distance(_ meters: Double) -> String {
        let m = max(0, meters)
        if m < 1000 {
            let rounded = Int((m / 10).rounded()) * 10
            return "\(rounded) m"
        }
        let km = (m / 100).rounded() / 10
        return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
    }

    /// "1", "13": a duration as a bare minute count for chips.
    static func wholeMinutes(_ seconds: Int) -> String {
        String(max(1, Int((Double(max(seconds, 0)) / 60).rounded())))
    }

    /// "3 stops" / "1 stop" for the timeline's intermediate-stop rows.
    static func stopCount(_ count: Int) -> String {
        count == 1 ? "1 stop" : "\(count) stops"
    }
}
