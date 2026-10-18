import CoreLocation
@testable import CustomMapApp

/// Real Dublin coordinates for scenario-based routing tests.
/// All coordinates verified against actual locations.
enum Dublin {

    // MARK: - City Centre

    /// O'Connell Street / GPO — heart of Dublin, near Luas Red+Green interchange
    static let oconnellStreet = CLLocationCoordinate2D(latitude: 53.3492, longitude: -6.2600)

    /// St. Stephen's Green — Luas Green Line terminus, south city centre
    static let stephensGreen = CLLocationCoordinate2D(latitude: 53.3390, longitude: -6.2613)

    /// Connolly Station — DART + Luas Red Line + Irish Rail hub
    static let connollyStation = CLLocationCoordinate2D(latitude: 53.3510, longitude: -6.2500)

    /// Heuston Station — Irish Rail mainline to west/south, Luas Red Line
    static let heustonStation = CLLocationCoordinate2D(latitude: 53.3465, longitude: -6.2924)

    /// Temple Bar — tourist area, between two Luas lines
    static let templeBar = CLLocationCoordinate2D(latitude: 53.3453, longitude: -6.2635)

    // MARK: - Along the Liffey (Luas territory)

    /// Smithfield — Luas Red Line, north of river
    static let smithfield = CLLocationCoordinate2D(latitude: 53.3472, longitude: -6.2780)

    /// Jervis Shopping Centre — Luas Red Line, city centre
    static let jervis = CLLocationCoordinate2D(latitude: 53.3474, longitude: -6.2655)

    /// Spencer Dock / IFSC — Luas Red Line, docklands
    static let spencerDock = CLLocationCoordinate2D(latitude: 53.3491, longitude: -6.2368)

    // MARK: - DART Coastal

    /// Bray — southern DART terminus, seaside town
    static let bray = CLLocationCoordinate2D(latitude: 53.2044, longitude: -6.0986)

    /// Dun Laoghaire — south Dublin coast, DART station + ferry port
    static let dunLaoghaire = CLLocationCoordinate2D(latitude: 53.2943, longitude: -6.1356)

    /// Howth — northern DART terminus, fishing village + cliff walk
    static let howth = CLLocationCoordinate2D(latitude: 53.3878, longitude: -6.0653)

    /// Malahide — northern DART, seaside village
    static let malahide = CLLocationCoordinate2D(latitude: 53.4507, longitude: -6.1543)

    // MARK: - Southwest Dublin (Bus-only territory, no Luas/DART)

    /// Tallaght — end of Luas Red Line, but surrounding areas are bus-only
    static let tallaght = CLLocationCoordinate2D(latitude: 53.2873, longitude: -6.3740)

    /// Clondalkin — southwest Dublin, bus-dependent suburb
    static let clondalkin = CLLocationCoordinate2D(latitude: 53.3205, longitude: -6.3945)

    /// Rathfarnham — south Dublin, no rail, bus routes to city
    static let rathfarnham = CLLocationCoordinate2D(latitude: 53.3010, longitude: -6.2830)

    /// Firhouse — further southwest, bus only
    static let firhouse = CLLocationCoordinate2D(latitude: 53.2830, longitude: -6.3350)

    // MARK: - Long Distance (Rail territory)

    /// Galway — west coast, ~200km from Dublin, InterCity rail
    static let galway = CLLocationCoordinate2D(latitude: 53.2707, longitude: -9.0568)

    /// Cork — south coast, ~250km from Dublin, InterCity rail
    static let cork = CLLocationCoordinate2D(latitude: 51.8985, longitude: -8.4756)

    /// Belfast — north, ~160km from Dublin, Enterprise rail
    static let belfast = CLLocationCoordinate2D(latitude: 54.5973, longitude: -5.9301)

    // MARK: - Suburban / Commuter Rail

    /// Maynooth — western commuter rail terminus
    static let maynooth = CLLocationCoordinate2D(latitude: 53.3846, longitude: -6.5935)

    /// Greystones — southern DART+ terminus
    static let greystones = CLLocationCoordinate2D(latitude: 53.1430, longitude: -6.0633)
}

// MARK: - Test Stop Builders

/// Create a TransitStop for testing with minimal boilerplate
func makeStop(
    id: String,
    name: String,
    lat: Double,
    lon: Double,
    type: TransitStop.TransitStopType = .bus
) -> TransitStop {
    TransitStop(id: id, name: name, latitude: lat, longitude: lon, type: type)
}

/// Create a GTFSTrip for testing
func makeTrip(
    tripId: String = "trip_1",
    routeId: String = "route_1",
    routeShortName: String = "39A",
    routeType: Int = 3,
    shapeId: String = ""
) -> GTFSTrip {
    GTFSTrip(
        tripId: tripId,
        routeId: routeId,
        serviceId: "service_1",
        directionId: 0,
        routeShortName: routeShortName,
        shapeId: shapeId,
        routeType: routeType
    )
}

/// Create a GTFSStopTime for testing
func makeStopTime(
    tripId: String = "trip_1",
    stopId: String,
    sequence: Int,
    departureSeconds: Int
) -> GTFSStopTime {
    let h = departureSeconds / 3600
    let m = (departureSeconds % 3600) / 60
    let s = departureSeconds % 60
    let timeStr = String(format: "%02d:%02d:%02d", h, m, s)
    return GTFSStopTime(
        tripId: tripId,
        stopId: stopId,
        arrivalTime: timeStr,
        departureTime: timeStr,
        stopSequence: sequence
    )
}
