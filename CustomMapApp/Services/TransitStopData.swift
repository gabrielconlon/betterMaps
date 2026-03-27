import CoreLocation

/// Hardcoded Luas stop coordinates. These are fixed infrastructure — they don't change.
/// Saves an API call and works offline.
struct LuasStopCoordinates {
    static let stops: [TransitStop] = [
        // Red Line
        TransitStop(id: "LUAS_TPT", name: "The Point", latitude: 53.3488, longitude: -6.2290, type: .luas),
        TransitStop(id: "LUAS_SDK", name: "Spencer Dock", latitude: 53.3491, longitude: -6.2368, type: .luas),
        TransitStop(id: "LUAS_MYS", name: "Mayor Square - NCI", latitude: 53.3494, longitude: -6.2434, type: .luas),
        TransitStop(id: "LUAS_GDK", name: "George's Dock", latitude: 53.3496, longitude: -6.2488, type: .luas),
        TransitStop(id: "LUAS_CON", name: "Connolly", latitude: 53.3510, longitude: -6.2500, type: .luas),
        TransitStop(id: "LUAS_BUS", name: "Busáras", latitude: 53.3502, longitude: -6.2534, type: .luas),
        TransitStop(id: "LUAS_ABB", name: "Abbey Street", latitude: 53.3486, longitude: -6.2584, type: .luas),
        TransitStop(id: "LUAS_JER", name: "Jervis", latitude: 53.3474, longitude: -6.2655, type: .luas),
        TransitStop(id: "LUAS_FOU", name: "Four Courts", latitude: 53.3468, longitude: -6.2730, type: .luas),
        TransitStop(id: "LUAS_SMI", name: "Smithfield", latitude: 53.3472, longitude: -6.2780, type: .luas),
        TransitStop(id: "LUAS_MUS", name: "Museum", latitude: 53.3476, longitude: -6.2864, type: .luas),
        TransitStop(id: "LUAS_HEU", name: "Heuston", latitude: 53.3465, longitude: -6.2924, type: .luas),
        TransitStop(id: "LUAS_JAM", name: "James's", latitude: 53.3437, longitude: -6.2943, type: .luas),
        TransitStop(id: "LUAS_FAT", name: "Fatima", latitude: 53.3395, longitude: -6.2930, type: .luas),
        TransitStop(id: "LUAS_RIA", name: "Rialto", latitude: 53.3374, longitude: -6.2955, type: .luas),
        TransitStop(id: "LUAS_SUI", name: "Suir Road", latitude: 53.3350, longitude: -6.3032, type: .luas),
        TransitStop(id: "LUAS_GOL", name: "Goldenbridge", latitude: 53.3340, longitude: -6.3100, type: .luas),
        TransitStop(id: "LUAS_DRI", name: "Drimnagh", latitude: 53.3325, longitude: -6.3158, type: .luas),
        TransitStop(id: "LUAS_BLA", name: "Blackhorse", latitude: 53.3307, longitude: -6.3235, type: .luas),
        TransitStop(id: "LUAS_BLU", name: "Bluebell", latitude: 53.3291, longitude: -6.3337, type: .luas),
        TransitStop(id: "LUAS_KYL", name: "Kylemore", latitude: 53.3264, longitude: -6.3429, type: .luas),
        TransitStop(id: "LUAS_RED", name: "Red Cow", latitude: 53.3176, longitude: -6.3640, type: .luas),
        TransitStop(id: "LUAS_BEL", name: "Belgard", latitude: 53.2998, longitude: -6.3753, type: .luas),
        TransitStop(id: "LUAS_TAL", name: "Tallaght", latitude: 53.2873, longitude: -6.3740, type: .luas),
        TransitStop(id: "LUAS_SAG", name: "Saggart", latitude: 53.2843, longitude: -6.4390, type: .luas),

        // Green Line
        TransitStop(id: "LUAS_BRO", name: "Broombridge", latitude: 53.3724, longitude: -6.2977, type: .luas),
        TransitStop(id: "LUAS_CAB", name: "Cabra", latitude: 53.3646, longitude: -6.2920, type: .luas),
        TransitStop(id: "LUAS_PHI", name: "Phibsborough", latitude: 53.3588, longitude: -6.2813, type: .luas),
        TransitStop(id: "LUAS_GRA", name: "Grangegorman", latitude: 53.3555, longitude: -6.2770, type: .luas),
        TransitStop(id: "LUAS_BRD", name: "Broadstone - DIT", latitude: 53.3531, longitude: -6.2735, type: .luas),
        TransitStop(id: "LUAS_DOM", name: "Dominick", latitude: 53.3516, longitude: -6.2690, type: .luas),
        TransitStop(id: "LUAS_PAR", name: "Parnell", latitude: 53.3530, longitude: -6.2634, type: .luas),
        TransitStop(id: "LUAS_OUP", name: "O'Connell Upper", latitude: 53.3522, longitude: -6.2611, type: .luas),
        TransitStop(id: "LUAS_OGP", name: "O'Connell GPO", latitude: 53.3492, longitude: -6.2600, type: .luas),
        TransitStop(id: "LUAS_MAR", name: "Marlborough", latitude: 53.3489, longitude: -6.2560, type: .luas),
        TransitStop(id: "LUAS_WES", name: "Westmoreland", latitude: 53.3460, longitude: -6.2590, type: .luas),
        TransitStop(id: "LUAS_TRI", name: "Trinity", latitude: 53.3445, longitude: -6.2577, type: .luas),
        TransitStop(id: "LUAS_DAW", name: "Dawson", latitude: 53.3412, longitude: -6.2581, type: .luas),
        TransitStop(id: "LUAS_STS", name: "St. Stephen's Green", latitude: 53.3390, longitude: -6.2613, type: .luas),
        TransitStop(id: "LUAS_HAR", name: "Harcourt", latitude: 53.3334, longitude: -6.2626, type: .luas),
        TransitStop(id: "LUAS_CHA", name: "Charlemont", latitude: 53.3308, longitude: -6.2592, type: .luas),
        TransitStop(id: "LUAS_RAN", name: "Ranelagh", latitude: 53.3264, longitude: -6.2564, type: .luas),
        TransitStop(id: "LUAS_BEE", name: "Beechwood", latitude: 53.3216, longitude: -6.2543, type: .luas),
        TransitStop(id: "LUAS_COW", name: "Cowper", latitude: 53.3168, longitude: -6.2535, type: .luas),
        TransitStop(id: "LUAS_MIL", name: "Milltown", latitude: 53.3106, longitude: -6.2509, type: .luas),
        TransitStop(id: "LUAS_WIN", name: "Windy Arbour", latitude: 53.3020, longitude: -6.2481, type: .luas),
        TransitStop(id: "LUAS_DUN", name: "Dundrum", latitude: 53.2924, longitude: -6.2449, type: .luas),
        TransitStop(id: "LUAS_BAL", name: "Balally", latitude: 53.2863, longitude: -6.2364, type: .luas),
        TransitStop(id: "LUAS_KIL", name: "Kilmacud", latitude: 53.2831, longitude: -6.2298, type: .luas),
        TransitStop(id: "LUAS_STI", name: "Stillorgan", latitude: 53.2790, longitude: -6.2184, type: .luas),
        TransitStop(id: "LUAS_SAN", name: "Sandyford", latitude: 53.2770, longitude: -6.2046, type: .luas),
        TransitStop(id: "LUAS_CPK", name: "Central Park", latitude: 53.2696, longitude: -6.2038, type: .luas),
        TransitStop(id: "LUAS_GLE", name: "Glencairn", latitude: 53.2642, longitude: -6.2088, type: .luas),
        TransitStop(id: "LUAS_GAL", name: "The Gallops", latitude: 53.2596, longitude: -6.2075, type: .luas),
        TransitStop(id: "LUAS_LEO", name: "Leopardstown Valley", latitude: 53.2551, longitude: -6.1989, type: .luas),
        TransitStop(id: "LUAS_BAW", name: "Ballyogan Wood", latitude: 53.2530, longitude: -6.1888, type: .luas),
        TransitStop(id: "LUAS_CAR", name: "Carrickmines", latitude: 53.2480, longitude: -6.1767, type: .luas),
        TransitStop(id: "LUAS_LAU", name: "Laughanstown", latitude: 53.2442, longitude: -6.1546, type: .luas),
        TransitStop(id: "LUAS_CHE", name: "Cherrywood", latitude: 53.2413, longitude: -6.1461, type: .luas),
        TransitStop(id: "LUAS_BRI", name: "Bride's Glen", latitude: 53.2380, longitude: -6.1424, type: .luas),
    ]

    /// Red Line stop IDs in order (The Point → Tallaght, with Belgard branch to Saggart)
    static let redLineMain: [String] = [
        "LUAS_TPT", "LUAS_SDK", "LUAS_MYS", "LUAS_GDK", "LUAS_CON", "LUAS_BUS",
        "LUAS_ABB", "LUAS_JER", "LUAS_FOU", "LUAS_SMI", "LUAS_MUS", "LUAS_HEU",
        "LUAS_JAM", "LUAS_FAT", "LUAS_RIA", "LUAS_SUI", "LUAS_GOL", "LUAS_DRI",
        "LUAS_BLA", "LUAS_BLU", "LUAS_KYL", "LUAS_RED", "LUAS_BEL", "LUAS_TAL"
    ]
    static let redLineSaggart: [String] = ["LUAS_BEL", "LUAS_SAG"]

    /// Green Line stop IDs in order (Broombridge → Bride's Glen)
    static let greenLine: [String] = [
        "LUAS_BRO", "LUAS_CAB", "LUAS_PHI", "LUAS_GRA", "LUAS_BRD", "LUAS_DOM",
        "LUAS_PAR", "LUAS_OUP", "LUAS_OGP", "LUAS_MAR", "LUAS_WES", "LUAS_TRI",
        "LUAS_DAW", "LUAS_STS", "LUAS_HAR", "LUAS_CHA", "LUAS_RAN", "LUAS_BEE",
        "LUAS_COW", "LUAS_MIL", "LUAS_WIN", "LUAS_DUN", "LUAS_BAL", "LUAS_KIL",
        "LUAS_STI", "LUAS_SAN", "LUAS_CPK", "LUAS_GLE", "LUAS_GAL", "LUAS_LEO",
        "LUAS_BAW", "LUAS_CAR", "LUAS_LAU", "LUAS_CHE", "LUAS_BRI"
    ]

    /// Convert a line's stop IDs to coordinates
    static func lineCoordinates(_ stopIds: [String]) -> [CLLocationCoordinate2D] {
        let lookup = Dictionary(uniqueKeysWithValues: stops.map { ($0.id, $0) })
        return stopIds.compactMap { lookup[$0]?.coordinate }
    }
}

// MARK: - DART Line Builder

/// Builds DART route lines from actual station coordinates in the transit stop data.
/// Uses station name matching (ordered) so lines pass through the real pin locations.
struct DARTLineBuilder {

    /// Ordered station names for each DART branch.
    /// The line is drawn by finding each station in the loaded transit stops
    /// and connecting their real coordinates in order.

    static let howthBranchNames = [
        "Howth", "Sutton", "Bayside", "Howth Junction"
    ]

    static let malahideBranchNames = [
        "Malahide", "Portmarnock", "Clongriffin"
    ]

    /// Clongriffin → Howth Junction (where branches merge)
    static let malahideToJunctionNames = ["Clongriffin", "Howth Junction"]

    /// Main coastal line: Howth Junction → Greystones
    static let mainLineNames = [
        "Howth Junction", "Kilbarrack", "Raheny", "Harmonstown",
        "Killester", "Clontarf Road", "Connolly", "Tara Street",
        "Pearse", "Grand Canal Dock", "Lansdowne Road", "Sandymount",
        "Sydney Parade", "Booterstown", "Blackrock", "Seapoint",
        "Salthill", "Monkstown", "Dún Laoghaire", "Dun Laoghaire",
        "Sandycove", "Glenageary", "Dalkey", "Killiney", "Shankill",
        "Bray", "Greystones"
    ]

    /// DART+ Western line: Maynooth direction → Connolly
    /// Route: Maynooth → Clonsilla → Broombridge → Drumcondra → Connolly
    static let westernLineNames = [
        "Maynooth", "Leixlip", "Coolmine", "Clonsilla",
        "Castleknock", "Navan Road", "Ashtown", "Broombridge",
        "Drumcondra", "Connolly"
    ]

    /// DART+ South-western: Kildare direction, branches from western line at Clonsilla
    /// Then goes south through Heuston to join the main line
    static let southWesternLineNames = [
        "Hazelhatch", "Adamstown", "Clondalkin", "Kishoge",
        "Park West", "Cherry Orchard", "Heuston"
    ]

    /// Build coordinates for a branch by matching station names against loaded transit stops.
    /// Falls back to partial matches (contains) for names like "Salthill & Monkstown".
    static func buildLine(names: [String], from stops: [TransitStop]) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        for name in names {
            let lowerName = name.lowercased()
            if let stop = stops.first(where: {
                ($0.type == .dart || $0.type == .rail) &&
                ($0.name.lowercased() == lowerName || $0.name.lowercased().contains(lowerName))
            }) {
                // Avoid duplicates (e.g., "Dún Laoghaire" and "Dun Laoghaire" both match)
                if let last = coords.last,
                   abs(last.latitude - stop.latitude) < 0.001 && abs(last.longitude - stop.longitude) < 0.001 {
                    continue
                }
                coords.append(stop.coordinate)
            }
        }
        return coords
    }
}

