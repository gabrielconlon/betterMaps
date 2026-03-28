import Foundation
import CoreLocation

// MARK: - NTA GTFS-RT Models (simplified JSON parsing — full GTFS-RT needs protobuf)

/// For the initial integration, we use NTA's JSON endpoints where available,
/// and the GTFS static feed for stop data. Full GTFS-RT (protobuf) is Phase 2.

struct NTAStopDeparture: Identifiable {
    let id = UUID()
    let routeShortName: String   // e.g., "39A", "145"
    let headsign: String         // e.g., "UCD Belfield"
    let dueIn: Int               // minutes
    let scheduledTime: String
    let isRealTime: Bool         // true if from GTFS-RT, false if scheduled
    let operator_: String        // "Dublin Bus", "Bus Éireann", "Go-Ahead"
    var routeId: String = ""     // GTFS route_id for shape lookup
    var tripId: String = ""      // GTFS trip_id for shape lookup
}

// MARK: - NTA Transit Service

actor NTATransitService {
    nonisolated(unsafe) static var apiKey: String = ""

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    // GTFS-RT endpoints from the NTA developer portal
    private let gtfsrBaseURL = "https://gtfsr.transportforireland.ie/v2"

    /// Fetch real-time stop passage info for a given stop
    /// Note: GTFS-RT doesn't have a per-stop JSON endpoint.
    /// The stop departures need to be extracted from the full TripUpdates feed,
    /// which requires protobuf parsing. For now this is best-effort.
    func fetchStopDepartures(stopId: String) async -> [NTAStopDeparture] {
        await APILogger.shared.log(service: "NTA", endpoint: "Departures/\(stopId)", status: .cached, durationMs: 0, detail: "Bus departures via GTFS coming soon")
        return []
    }

    /// Fetch service alerts
    func fetchServiceAlerts() async -> [NTAServiceAlert] {
        await APILogger.shared.log(service: "NTA", endpoint: "ServiceAlerts", status: .cached, durationMs: 0, detail: "Service alerts endpoint not available")
        return []
    }

    // MARK: - JSON Parsing (best-effort — exact format depends on NTA endpoint version)

    private func parseDeparturesJSON(data: Data) -> [NTAStopDeparture]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Try common RTPI JSON structures
        var departures: [NTAStopDeparture] = []

        // Structure 1: { "results": [ { ... } ] }
        if let results = json["results"] as? [[String: Any]] {
            for result in results {
                if let departure = parseSingleDeparture(result) {
                    departures.append(departure)
                }
            }
        }

        // Structure 2: { "entity": [ { "trip_update": { ... } } ] }  (GTFS-RT JSON)
        if let entities = json["entity"] as? [[String: Any]] {
            for entity in entities {
                if let tripUpdate = entity["trip_update"] as? [String: Any],
                   let stopTimeUpdates = tripUpdate["stop_time_update"] as? [[String: Any]] {
                    for update in stopTimeUpdates {
                        if let departure = parseGTFSRTDeparture(update, trip: tripUpdate) {
                            departures.append(departure)
                        }
                    }
                }
            }
        }

        return departures.isEmpty ? nil : departures.sorted { $0.dueIn < $1.dueIn }
    }

    private func parseSingleDeparture(_ dict: [String: Any]) -> NTAStopDeparture? {
        let route = dict["route"] as? String ?? dict["routeShortName"] as? String ?? ""
        let headsign = dict["destination"] as? String ?? dict["headsign"] as? String ?? ""
        let dueIn = dict["duetime"] as? Int ?? dict["dueIn"] as? Int ?? 0
        let scheduled = dict["scheduledtime"] as? String ?? dict["scheduled"] as? String ?? ""
        let realtime = dict["monitored"] as? Bool ?? dict["isRealTime"] as? Bool ?? false
        let op = dict["operator"] as? String ?? dict["agency"] as? String ?? ""

        guard !route.isEmpty || !headsign.isEmpty else { return nil }

        return NTAStopDeparture(
            routeShortName: route,
            headsign: headsign,
            dueIn: dueIn,
            scheduledTime: scheduled,
            isRealTime: realtime,
            operator_: op
        )
    }

    private func parseGTFSRTDeparture(_ update: [String: Any], trip: [String: Any]) -> NTAStopDeparture? {
        let tripInfo = trip["trip"] as? [String: Any] ?? [:]
        let routeId = tripInfo["route_id"] as? String ?? ""

        let arrival = update["arrival"] as? [String: Any]
        let delay = arrival?["delay"] as? Int ?? 0

        return NTAStopDeparture(
            routeShortName: routeId,
            headsign: "",
            dueIn: max(0, delay / 60),
            scheduledTime: "",
            isRealTime: true,
            operator_: ""
        )
    }

    private func parseAlertsJSON(data: Data) -> [NTAServiceAlert]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var alerts: [NTAServiceAlert] = []

        if let entities = json["entity"] as? [[String: Any]] {
            for entity in entities {
                if let alert = entity["alert"] as? [String: Any] {
                    let headerText = (alert["header_text"] as? [String: Any])?["translation"] as? [[String: Any]]
                    let descText = (alert["description_text"] as? [String: Any])?["translation"] as? [[String: Any]]

                    let header = headerText?.first?["text"] as? String ?? ""
                    let desc = descText?.first?["text"] as? String ?? ""

                    if !header.isEmpty {
                        alerts.append(NTAServiceAlert(header: header, description: desc))
                    }
                }
            }
        }

        return alerts.isEmpty ? nil : alerts
    }
}

struct NTAServiceAlert: Identifiable {
    let id = UUID()
    let header: String
    let description: String
}
