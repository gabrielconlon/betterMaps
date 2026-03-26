import SwiftUI
import CoreLocation

struct TransitArrivalsView: View {
    let stationName: String
    let coordinate: CLLocationCoordinate2D

    @State private var railArrivals: [IrishRailArrival] = []
    @State private var luasForecast: LuasStopForecast?
    @State private var busDepartures: [NTAStopDeparture] = []
    @State private var serviceAlerts: [NTAServiceAlert] = []
    @State private var isLoading = true
    @State private var hasRail = false
    @State private var hasLuas = false

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

                if isLoading {
                    HStack { Spacer(); ProgressView("Loading arrivals..."); Spacer() }
                        .padding()
                }

                // Luas arrivals
                if let forecast = luasForecast {
                    if !forecast.message.isEmpty {
                        Label(forecast.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
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

                if !isLoading && railArrivals.isEmpty && luasForecast == nil && busDepartures.isEmpty {
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

        // Check if near a Luas stop (within ~300m)
        let nearbyLuas = LuasService.stops.first { stop in
            // Simple distance check — Luas stops don't have coordinates in the basic API
            // So we match by name similarity with the tapped station name
            stationName.localizedCaseInsensitiveContains(stop.name) ||
            stop.name.localizedCaseInsensitiveContains(stationName)
        }

        if let luasStop = nearbyLuas {
            hasLuas = true
            luasForecast = await luasService.fetchForecast(stopCode: luasStop.id)
        }

        // Check Irish Rail — fetch all stations and find nearby
        let allStations = await railService.fetchStations()
        let nearbyStation = allStations.first { station in
            let stationLoc = CLLocation(latitude: station.latitude, longitude: station.longitude)
            let tapLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return stationLoc.distance(from: tapLoc) < 500 // within 500m
        }

        if let station = nearbyStation {
            hasRail = true
            railArrivals = await railService.fetchArrivals(stationCode: station.id)
        }

        // NTA bus departures (if API key configured)
        // NOTE: We need the stop ID for the NTA API. For now, try the station name
        // as a stop reference. Full GTFS stop matching is Phase 3.
        if NTATransitService.isConfigured {
            // Try fetching with a stop ID derived from the station name
            // In practice, you'd match to GTFS stop_id from the static feed
            let stopId = stationName.replacingOccurrences(of: " ", with: "")
                .prefix(10).lowercased()
            busDepartures = await ntaService.fetchStopDepartures(stopId: String(stopId))
            serviceAlerts = await ntaService.fetchServiceAlerts()
        }

        isLoading = false
    }
}
