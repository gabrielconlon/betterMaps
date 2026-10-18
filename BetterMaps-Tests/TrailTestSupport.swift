import Foundation
import SwiftData
import CoreLocation
@testable import CustomMapApp

/// In-memory container for tests that touch `Place`, `Layer` and `Trail`.
/// Never reads or writes the app's on-disk store.
@MainActor
func makeTestContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Place.self, Layer.self, Trail.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

enum TestCoords {
    // A short east-west run along the Grand Canal in Dublin.
    static let a = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2600)
    static let b = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2500)
    static let c = CLLocationCoordinate2D(latitude: 53.3500, longitude: -6.2500)
    static let d = CLLocationCoordinate2D(latitude: 53.3500, longitude: -6.2400)
    static let e = CLLocationCoordinate2D(latitude: 53.3600, longitude: -6.2400)
    static let f = CLLocationCoordinate2D(latitude: 53.3600, longitude: -6.2300)
    static let g = CLLocationCoordinate2D(latitude: 53.3700, longitude: -6.2300)
}
