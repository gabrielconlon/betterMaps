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

    // Hex equivalents — used by TransitStopType.colorHex for pin rendering and
    // by sidebar legends. Keep in lock-step with the Color values above.
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

    /// Luas Red line — pastel coral with the same .opacity treatment as the
    /// other network lines so all four (LuasRed/LuasGreen/DART/Rail) read
    /// as a coherent overlay set.
    static let luasRedLayer = luasRedPin.opacity(0.7)
}
