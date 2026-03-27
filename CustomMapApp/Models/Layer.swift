import Foundation
import SwiftData

@Model
final class Layer {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#FF3B30"
    var symbolName: String = "mappin"
    var isVisible: Bool = true
    var isFavorite: Bool = false
    var sortOrder: Int = 0
    var places: [Place]? = []
    var createdAt: Date = Date()

    init(
        name: String = "",
        colorHex: String = "#FF3B30",
        symbolName: String = "mappin",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }
}
