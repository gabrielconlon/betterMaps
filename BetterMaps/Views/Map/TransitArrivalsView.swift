import SwiftUI
import CoreLocation

struct TransitArrivalsView: View {
    let stationName: String
    let coordinate: CLLocationCoordinate2D
    var stopType: TransitStop.TransitStopType?  // When set, only fetch data for this type
    var stopCode: String?  // Public-facing stop number from GTFS stop_code
    var stopId: String?    // GTFS stop_id for favoriting
    /// Callback when user taps a bus route to view it on the map
    var onSelectRoute: ((String, String) -> Void)?  // (routeId, routeName)

    @State private var railArrivals: [IrishRailArrival] = []
    @State private var luasForecast: LuasStopForecast?
    @State private var busDepartures: [NTAStopDeparture] = []
    @State private var serviceAlerts: [NTAServiceAlert] = []
    @State private var isLoading = true
    @State private var hasRail = false
    @State private var hasLuas = false
    @State private var busFetchAttempted = false
    @State private var busRoutes: [(routeId: String, routeName: String)] = []

    private let railService = IrishRailService()
    private let luasService = LuasService()
    private let ntaService = NTATransitService()

    /// Filter rail arrivals by stop type — DART-only shows DART trains, Rail-only shows non-DART
    private var filteredRailArrivals: [IrishRailArrival] {
        guard !railArrivals.isEmpty else { return [] }
        switch stopType {
        case .dart:
            return railArrivals.filter { $0.trainType.uppercased() == "DART" }
        case .rail:
            return railArrivals.filter { $0.trainType.uppercased() != "DART" }
        default:
            return railArrivals // show all when type is nil or mixed
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Drag indicator
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 40, height: 5)
                    Spacer()
                }
                .padding(.top, 8)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stationName)
                        .font(.title3.bold())
                    if let stopCode {
                        Text("Stop \(stopCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if let stopId {
                        FavoriteStopButton(stopId: stopId)
                    }
                }

                // Only show loading spinner when no data has arrived yet
                if isLoading && luasForecast == nil && railArrivals.isEmpty && busDepartures.isEmpty {
                    HStack { Spacer(); ProgressView("Loading arrivals..."); Spacer() }
                        .padding()
                }

                // Luas arrivals
                if let forecast = luasForecast {
                    if !forecast.message.isEmpty {
                        let isNormal = forecast.message.localizedCaseInsensitiveContains("operating normally")
                            || forecast.message.localizedCaseInsensitiveContains("normal service")
                        if isNormal {
                            Label(forecast.message, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label(forecast.message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !forecast.inbound.isEmpty {
                        arrivalSection(title: "Inbound", forecasts: forecast.inbound, color: .blue)
                    }
                    if !forecast.outbound.isEmpty {
                        arrivalSection(title: "Outbound", forecasts: forecast.outbound, color: .green)
                    }
                }

                // Irish Rail arrivals (filtered by stop type if set)
                if !filteredRailArrivals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stopType == .dart ? "DART" : stopType == .rail ? "Rail" : "Trains")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        ForEach(filteredRailArrivals) { arrival in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(arrival.destination)
                                            .font(.subheadline.bold())
                                        Text("(\(arrival.trainType))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("from \(arrival.origin)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !arrival.status.isEmpty {
                                        Text(arrival.status)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing) {
                                    Text(arrival.dueIn == 0 ? "DUE" : "\(arrival.dueIn) min")
                                        .font(.headline)
                                        .foregroundStyle(arrival.dueIn <= 3 ? .red : .primary)
                                    Text(arrival.expectedArrival)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                // Routes serving this stop
                if !busRoutes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Routes at this stop")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 6) {
                            ForEach(busRoutes, id: \.routeId) { route in
                                Button(action: {
                                    onSelectRoute?(route.routeId, route.routeName)
                                }) {
                                    Text(route.routeName)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }

                // Bus departures
                if !busDepartures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Next Departures")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let age = GTFSDatabase.ageDescription {
                                Text(age)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        ForEach(busDepartures) { dep in
                            Button(action: {
                                if !dep.routeId.isEmpty {
                                    onSelectRoute?(dep.routeId, dep.routeShortName)
                                }
                            }) {
                                HStack {
                                    Text(dep.routeShortName)
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.blue.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dep.headsign)
                                            .font(.subheadline)
                                        if !dep.operator_.isEmpty {
                                            Text(dep.operator_)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing) {
                                        Text(dep.dueIn == 0 ? "DUE" : "\(dep.dueIn) min")
                                            .font(.headline)
                                            .foregroundStyle(dep.dueIn <= 3 ? .red : .primary)
                                        if dep.isRealTime {
                                            Text("Live")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }

                                    if !dep.routeId.isEmpty {
                                        Image(systemName: "map")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                // Bus timetables placeholder
                if busFetchAttempted && busDepartures.isEmpty {
                    Label("No bus departures found nearby", systemImage: "bus.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Service alerts
                if !serviceAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Service Alerts")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        ForEach(serviceAlerts) { alert in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.header)
                                    .font(.caption.bold())
                                if !alert.description.isEmpty {
                                    Text(alert.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !isLoading && filteredRailArrivals.isEmpty && luasForecast == nil && busDepartures.isEmpty && !busFetchAttempted {
                    Text("No real-time arrivals available for this location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .task {
            await loadArrivals()
        }
    }

    @ViewBuilder
    private func arrivalSection(title: String, forecasts: [LuasForecast], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ForEach(forecasts) { forecast in
                HStack {
                    Image(systemName: "tram.fill")
                        .foregroundStyle(color)
                        .frame(width: 20)
                    Text(forecast.destination)
                        .font(.subheadline)
                    Spacer()
                    Text(forecast.dueIn)
                        .font(.headline)
                        .foregroundStyle(forecast.dueMinutes == 0 ? .red : .primary)
                }
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func loadArrivals() async {
        isLoading = true

        let shouldCheckLuas = stopType == nil || stopType == .luas
        let shouldCheckRail = stopType == nil || stopType == .dart || stopType == .rail
        let shouldCheckBus = stopType == nil || stopType == .bus

        // Check Luas (only if stop type matches or unknown)
        if shouldCheckLuas {
            // Match by station name against the Luas forecast API stop list.
            // GTFS stop names may differ slightly (e.g. "Cabra Luas Stop" vs "Cabra"),
            // so we use contains-matching on the canonical Luas stop name.
            let lowerName = stationName.lowercased()
            let matchedStop = LuasService.stops.first { luasStop in
                let luasName = luasStop.name.lowercased()
                return lowerName.contains(luasName) || luasName.contains(lowerName)
            }
            if let matchedStop {
                hasLuas = true
                luasForecast = await luasService.fetchForecast(stopCode: matchedStop.id)
            }
        }

        // Check Irish Rail (only if stop type matches or unknown)
        if shouldCheckRail {
            let allStations = await railService.fetchStations()
            let tapLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let nearbyStation = allStations.first { station in
                let stationLoc = CLLocation(latitude: station.latitude, longitude: station.longitude)
                return stationLoc.distance(from: tapLoc) < 800
            }

            if let station = nearbyStation {
                hasRail = true
                railArrivals = await railService.fetchArrivals(stationCode: station.id)
            }
        }

        // Bus departures from GTFS SQLite database
        busFetchAttempted = shouldCheckBus
        if shouldCheckBus {
            // Ensure SQLite database is ready (instant if already built, downloads if first time)
            await GTFSScheduleService.shared.loadIfNeeded()

            let tapLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

            let loader = GTFSStopLoader()
            let gtfsStops = await loader.loadStops()
            let nearbyBusStop = gtfsStops
                .filter { $0.type == .bus }
                .map { stop in
                    let stopLoc = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
                    return (stop: stop, distance: stopLoc.distance(from: tapLoc))
                }
                .filter { $0.distance < 200 }
                .min(by: { $0.distance < $1.distance })

            if let busStop = nearbyBusStop {
                var irishCal = Calendar.current
                irishCal.timeZone = TimeZone(identifier: "Europe/Dublin")!
                let now = Date()
                let secondsSinceMidnight = irishCal.component(.hour, from: now) * 3600 +
                    irishCal.component(.minute, from: now) * 60 +
                    irishCal.component(.second, from: now)

                // Query routes that serve this stop
                let routes = await GTFSScheduleService.shared.routesForStop(stopId: busStop.stop.id)
                busRoutes = routes

                // Pre-compute active services for correct calendar filtering
                let activeServices = await GTFSScheduleService.shared.activeServiceIds(for: now)

                // Query next departures
                let departures = await GTFSScheduleService.shared.departuresFromStop(
                    stopId: busStop.stop.id,
                    afterSeconds: secondsSinceMidnight,
                    withinSeconds: 3600,
                    activeServices: activeServices
                )

                busDepartures = departures.prefix(10).map { stopTime, trip in
                    let dueMinutes = max(0, (stopTime.departureSeconds - secondsSinceMidnight) / 60)
                    return NTAStopDeparture(
                        routeShortName: trip.routeShortName,
                        headsign: trip.directionId == 0 ? "Outbound" : "Inbound",
                        dueIn: dueMinutes,
                        scheduledTime: stopTime.departureTime,
                        isRealTime: false,
                        operator_: "",
                        routeId: trip.routeId,
                        tripId: trip.tripId
                    )
                }
            }
        }

        isLoading = false
    }
}

// MARK: - Flow Layout (wrapping horizontal layout for route pills)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Favorite Stop Button

struct FavoriteStopButton: View {
    let stopId: String
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    private var isFavorite: Bool {
        profiles.first?.favoriteStopIds.contains(stopId) ?? false
    }

    var body: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .font(.title3)
        }
    }

    private func toggleFavorite() {
        guard let profile = profiles.first else {
            // Create profile if none exists
            let newProfile = UserProfile()
            newProfile.favoriteStopIds = [stopId]
            modelContext.insert(newProfile)
            return
        }
        if let idx = profile.favoriteStopIds.firstIndex(of: stopId) {
            profile.favoriteStopIds.remove(at: idx)
        } else {
            profile.favoriteStopIds.append(stopId)
        }
        profile.updatedAt = Date()
    }
}
