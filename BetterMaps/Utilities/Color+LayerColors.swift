import SwiftUI

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6,
              let rgb = UInt64(hexSanitized, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    /// Light fills (yellow, the pastel transit colours) take dark text.
    static func prefersDarkText(hex: String) -> Bool {
        let clean = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return false }
        func lin(_ c: UInt64) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin((rgb >> 16) & 0xFF) + 0.7152 * lin((rgb >> 8) & 0xFF) + 0.0722 * lin(rgb & 0xFF)
        return l > 0.4
    }

    func toHex() -> String {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return "#FF3B30"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static let layerPalette: [(name: String, hex: String)] = [
        ("Red", "#FF3B30"),
        ("Orange", "#FF9500"),
        ("Yellow", "#FFCC00"),
        ("Green", "#34C759"),
        ("Teal", "#5AC8FA"),
        ("Blue", "#007AFF"),
        ("Indigo", "#5856D6"),
        ("Purple", "#AF52DE"),
        ("Pink", "#FF2D55"),
        ("Brown", "#A2845E"),
    ]

    static let layerSymbols: [(name: String, symbol: String)] = [
        // General
        ("Pin", "mappin"),
        ("Star", "star.fill"),
        ("Heart", "heart.fill"),
        ("Bookmark", "bookmark.fill"),
        ("Flag", "flag.fill"),

        // Food & Drink
        ("Restaurant", "fork.knife"),
        ("Coffee", "cup.and.saucer.fill"),
        ("Brunch", "takeoutbag.and.cup.and.straw.fill"),
        ("Bar", "wineglass.fill"),
        ("Beer", "mug.fill"),
        ("Pizza", "fork.knife.circle.fill"),

        // Work & Productivity
        ("Work", "briefcase.fill"),
        ("Laptop", "laptopcomputer"),
        ("Wifi", "wifi"),
        ("Meeting", "person.2.fill"),
        ("Office", "building.2.fill"),

        // Home & Life
        ("Home", "house.fill"),
        ("Shopping", "bag.fill"),
        ("Cart", "cart.fill"),
        ("Laundry", "washer.fill"),

        // Health & Fitness
        ("Gym", "figure.run"),
        ("Yoga", "figure.mind.and.body"),
        ("Bike", "bicycle"),
        ("Swim", "figure.pool.swim"),
        ("Medical", "cross.case.fill"),

        // Transport
        ("Gas", "fuelpump.fill"),
        ("Parking", "p.circle.fill"),
        ("Train", "tram.fill"),
        ("Airport", "airplane"),
        ("EV Charge", "bolt.car.fill"),

        // Nature & Outdoors
        ("Park", "leaf.fill"),
        ("Beach", "beach.umbrella.fill"),
        ("Mountain", "mountain.2.fill"),
        ("Dog Park", "dog.fill"),
        ("Garden", "tree.fill"),

        // Entertainment
        ("Music", "music.note"),
        ("Movie", "film.fill"),
        ("Museum", "building.columns.fill"),
        ("Theater", "theatermasks.fill"),
        ("Game", "gamecontroller.fill"),

        // Other
        ("Camera", "camera.fill"),
        ("Book", "book.fill"),
        ("School", "graduationcap.fill"),
        ("Church", "cross.fill"),
        ("Bank", "banknote.fill"),
        ("Hotel", "bed.double.fill"),
        ("Phone", "phone.fill"),
        ("Globe", "globe.americas.fill"),
    ]
}

// MARK: - Centralized Transit Colors

/// Transit network palette is deliberately PASTEL so it never collides with the
/// vibrant custom-layer palette in `Color.layerPalette`. A user picking "Green"
/// for a custom layer (#34C759, fully saturated) sees a clearly different color
/// from the Luas Green line overlay (mint pastel) — the network reads as
/// "background infrastructure" while custom places stay as the foreground story.
///
/// Within transit, pins and lines share a hue so a stop visibly belongs to its
/// route: DART pin = peach, DART line = peach. Rail pin = lilac, Rail line = lilac.
/// Luas is split: Red-line stops get the coral pin, Green-line stops get the mint
/// pin — this is what the user means by "the red line should have red icons".
enum TransitColors {
    // Pastel pin colors — used for both stop annotations and as the base for
    // line strokes (lines just apply .opacity(0.7) on top).
    static let busPin     = Color(red: 0.46, green: 0.66, blue: 1.00)  // pastel cornflower
    static let luasRedPin = Color(red: 1.00, green: 0.55, blue: 0.55)  // pastel coral
    static let luasGrnPin = Color(red: 0.50, green: 0.81, blue: 0.63)  // pastel mint
    static let dartPin    = Color(red: 1.00, green: 0.72, blue: 0.48)  // pastel peach
    static let railPin    = Color(red: 0.76, green: 0.61, blue: 0.91)  // pastel lilac

    // Hex equivalents — used by `pinHex(_:)` and by sidebar legends. Keep in lock-step with the Color values above.
    static let busPinHex     = "#75A8FF"
    static let luasRedPinHex = "#FF8C8C"
    static let luasGrnPinHex = "#7FCEA1"
    static let dartPinHex    = "#FFB87A"
    static let railPinHex    = "#C39BE8"

    /// Background line color for the Luas/DART/Rail network overlay. Same hue
    /// as the pin so a stop and its line visibly share identity.
    static func layer(_ kind: TransitLayerKind) -> Color {
        switch kind {
        case .bus:  return busPin.opacity(0.7)
        case .luas: return luasGrnPin.opacity(0.7)   // Green line — Red is `luasRedLayer`
        case .dart: return dartPin.opacity(0.7)
        case .rail: return railPin.opacity(0.7)
        }
    }

    /// Pin hex for a network (Luas = Green; Red-line stops use `pin(for:)`).
    static func pinHex(_ kind: TransitLayerKind) -> String {
        switch kind {
        case .bus:  return busPinHex
        case .luas: return luasGrnPinHex
        case .dart: return dartPinHex
        case .rail: return railPinHex
        }
    }

    static func pin(_ kind: TransitLayerKind) -> Color {
        switch kind {
        case .bus:  return busPin
        case .luas: return luasGrnPin
        case .dart: return dartPin
        case .rail: return railPin
        }
    }

    /// The one colour source for a network + Luas line: Luas Red is coral,
    /// Luas Green mint, DART peach, other rail lilac, bus cornflower.
    /// Pins, network lines and route chips all resolve through here.
    static func pin(_ kind: TransitLayerKind, line: String?) -> Color {
        if kind == .luas && line?.lowercased() == "red" { return luasRedPin }
        return pin(kind)
    }

    /// Pin color for a stop: Luas Red-line stops are coral, everything else
    /// takes its network color.
    static func pin(for stop: TransitStop) -> Color {
        pin(stop.kind, line: stop.line)
    }

    /// Colour for a GTFS route (route chips): same hue as its stops' pins.
    static func pin(for route: TransitRoute) -> Color {
        pin(route.kind, line: route.kind == .luas ? route.short : nil)
    }

    /// `pin(for:)` from a stored route's GTFS type and short name.
    static func pin(routeType: Int, shortName: String) -> Color {
        pin(for: TransitRoute(id: "", short: shortName, long: "", type: routeType))
    }

    /// Stroke for a network line; the Luas Red line is coral.
    static func line(for line: TransitLine) -> Color {
        pin(line.kind, line: line.line).opacity(0.7)
    }

    /// Highlighted (favorite-chip) route stroke.
    static let highlightedRoute = Color.blue.opacity(0.85)

    /// Walking legs of a directions option: neutral in both themes.
    static let walkLeg = Color(.systemGray)
    /// Cycling legs: a green that stays legible on light and dark maps.
    static let bikeLeg = Color(red: 0.24, green: 0.68, blue: 0.42)

    /// Stroke and chip colour for one leg of an itinerary. Transit legs
    /// share their network's pin hue (Luas Red stays coral).
    static func leg(for leg: Leg) -> Color {
        switch leg.mode {
        case .walk: return walkLeg
        case .bike: return bikeLeg
        case .luas: return pin(.luas, line: leg.routeShortName?.lowercased())
        case .bus, .dart, .rail: return pin(leg.mode.layerKind ?? .bus)
        }
    }

    // MARK: Directions on the map

    /// Map strokes for directions: deeper versions of the network hues. The
    /// pastel pins and network lines are background on purpose, which made a
    /// journey drawn in them hard to pick out over the street grid (Gabe,
    /// 2026-10-31). A route is the foreground story, so it takes the same
    /// hue at full strength, over a casing (`routeCasing`).
    static func routeLeg(for leg: Leg) -> Color {
        switch leg.mode {
        case .walk: return routeWalk
        case .bike: return Color(red: 0.13, green: 0.55, blue: 0.30)
        case .luas:
            return leg.routeShortName?.lowercased() == "red"
                ? Color(red: 0.86, green: 0.20, blue: 0.22)
                : Color(red: 0.10, green: 0.60, blue: 0.33)
        case .dart: return Color(red: 0.93, green: 0.47, blue: 0.08)
        case .rail: return Color(red: 0.53, green: 0.29, blue: 0.80)
        case .bus: return Color(red: 0.15, green: 0.42, blue: 0.92)
        }
    }

    /// Walking legs on the map: dark slate on a light map, light grey on a
    /// dark one. `systemGray` vanished into the grey road casing.
    static let routeWalk = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.85, alpha: 1)
            : UIColor(red: 0.30, green: 0.33, blue: 0.38, alpha: 1)
    })

    /// Wider stroke drawn under every directions leg so it stands off the
    /// streets and transit lines it runs along: white on a light map, near
    /// black on a dark one.
    static let routeCasing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.08, alpha: 0.9)
            : UIColor(white: 1.0, alpha: 0.95)
    })

    /// Luas Red line — pastel coral with the same .opacity treatment as the
    /// other network lines so all four (LuasRed/LuasGreen/DART/Rail) read
    /// as a coherent overlay set.
    static let luasRedLayer = luasRedPin.opacity(0.7)
}
