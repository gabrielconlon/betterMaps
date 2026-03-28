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
