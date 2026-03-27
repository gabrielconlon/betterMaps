import SwiftUI
import CoreLocation

struct TransitArrivalsView: View {
    let stationName: String
    let coordinate: CLLocationCoordinate2D
    var stopType: TransitStop.TransitStopType?  // When set, only fetch data for this type

    @State private var railArrivals: [IrishRailArrival] = []
    @State private var luasForecast: LuasStopForecast?
    @State private var busDepartures: [NTAStopDeparture] = []
    @State private var serviceAlerts: [NTAServiceAlert] = []
    @State private var isLoading = true
    @State private var hasRail = false
    @State private var hasLuas = false
    @State private var busFetchAttempted = false

    private let railService = IrishRailService()
    private let luasService = LuasService()
    private let ntaService = NTATransitService()

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

                Text(stationName)
                    .font(.title3.bold())

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

                // Irish Rail arrivals
                if !railArrivals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trains")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        ForEach(railArrivals) { arrival in
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

                // NTA Bus departures
                if !busDepartures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bus")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        ForEach(busDepartures) { dep in
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
                            }
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

                if !isLoading && railArrivals.isEmpty && luasForecast == nil && busDepartures.isEmpty && !busFetchAttempted {
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
            let tapLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let nearbyLuasCoord = LuasStopCoordinates.stops
                .map { stop in
                    let stopLoc = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
                    return (stop: stop, distance: stopLoc.distance(from: tapLocation))
                }
                .filter { $0.distance < 300 }
                .min(by: { $0.distance < $1.distance })

            if let match = nearbyLuasCoord {
                hasLuas = true
                let stopCode = String(match.stop.id.replacingOccurrences(of: "LUAS_", with: ""))
                luasForecast = await luasService.fetchForecast(stopCode: stopCode)
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

        // Bus departures from GTFS schedule data (pre-loaded at app startup)
        busFetchAttempted = shouldCheckBus
        if shouldCheckBus {
            let tapLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

            // Use cached GTFS stops (already loaded at startup, hits cache instantly)
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
                let calendar = Calendar.current
                let now = Date()
                let secondsSinceMidnight = calendar.component(.hour, from: now) * 3600 +
                    calendar.component(.minute, from: now) * 60 +
                    calendar.component(.second, from: now)

                // Schedule data is pre-loaded at startup — no download needed
                let departures = await GTFSScheduleService.shared.departuresFromStop(
                    stopId: busStop.stop.id,
                    afterSeconds: secondsSinceMidnight,
                    withinSeconds: 3600
                )

                busDepartures = departures.prefix(10).map { stopTime, trip in
                    let dueMinutes = max(0, (stopTime.departureSeconds - secondsSinceMidnight) / 60)
                    return NTAStopDeparture(
                        routeShortName: trip.routeShortName,
                        headsign: trip.directionId == 0 ? "Outbound" : "Inbound",
                        dueIn: dueMinutes,
                        scheduledTime: stopTime.departureTime,
                        isRealTime: false,
                        operator_: ""
                    )
                }
            }
        }

        isLoading = false
    }
}
