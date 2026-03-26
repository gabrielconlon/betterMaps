import Foundation
import CoreLocation

// MARK: - Irish Rail Models

struct IrishRailStation: Identifiable {
    let id: String           // StationCode
    let name: String
    let latitude: Double
    let longitude: Double
    let type: StationType    // DART, Mainline, Suburban

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum StationType: String {
        case dart = "D"
        case mainline = "M"
        case suburban = "S"
        case all = "A"

        var displayName: String {
            switch self {
            case .dart: return "DART"
            case .mainline: return "Mainline"
            case .suburban: return "Suburban"
            case .all: return "All"
            }
        }
    }
}

struct IrishRailArrival: Identifiable {
    let id = UUID()
    let trainCode: String
    let origin: String
    let destination: String
    let dueIn: Int              // minutes
    let expectedArrival: String
    let expectedDeparture: String
    let status: String
    let direction: String
    let trainType: String       // DART, Mainline, etc.
    let lastLocation: String
}

// MARK: - Irish Rail Service

actor IrishRailService {
    private let baseURL = "http://api.irishrail.ie/realtime/realtime.asmx"

    /// Fetch all stations, optionally filtered by type
    func fetchStations(type: IrishRailStation.StationType = .all) async -> [IrishRailStation] {
        let endpoint: String
        if type == .all {
            endpoint = "\(baseURL)/getAllStationsXML"
        } else {
            endpoint = "\(baseURL)/getAllStationsXML_WithStationType?StationType=\(type.rawValue)"
        }

        guard let url = URL(string: endpoint) else { return [] }
        let start = Date()

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let parser = IrishRailStationParser(data: data)
            let stations = parser.parse()
            await APILogger.shared.log(service: "Irish Rail", endpoint: "getAllStations", status: .success, durationMs: ms)
            return stations
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.log(service: "Irish Rail", endpoint: "getAllStations", status: .failure, durationMs: ms, detail: error.localizedDescription)
            return []
        }
    }

    /// Fetch real-time arrivals for a station
    func fetchArrivals(stationCode: String, withinMinutes: Int = 30) async -> [IrishRailArrival] {
        let endpoint = "\(baseURL)/getStationDataByCodeXML_WithNumMins?StationCode=\(stationCode)&NumMins=\(withinMinutes)"
        guard let url = URL(string: endpoint) else { return [] }
        let start = Date()

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let parser = IrishRailArrivalParser(data: data)
            let arrivals = parser.parse()
            await APILogger.shared.log(service: "Irish Rail", endpoint: "getStationData/\(stationCode)", status: .success, durationMs: ms)
            return arrivals
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.log(service: "Irish Rail", endpoint: "getStationData/\(stationCode)", status: .failure, durationMs: ms, detail: error.localizedDescription)
            return []
        }
    }
}

// MARK: - XML Parsers

class IrishRailStationParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var stations: [IrishRailStation] = []
    private var currentElement = ""
    private var currentCode = ""
    private var currentName = ""
    private var currentLat = ""
    private var currentLng = ""
    private var currentType = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> [IrishRailStation] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return stations
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "objStation" {
            currentCode = ""
            currentName = ""
            currentLat = ""
            currentLng = ""
            currentType = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch currentElement {
        case "StationCode": currentCode += trimmed
        case "StationDesc": currentName += trimmed
        case "StationLatitude": currentLat += trimmed
        case "StationLongitude": currentLng += trimmed
        case "StationType": currentType += trimmed
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "objStation" {
            if let lat = Double(currentLat), let lng = Double(currentLng) {
                let type = IrishRailStation.StationType(rawValue: currentType) ?? .mainline
                stations.append(IrishRailStation(
                    id: currentCode,
                    name: currentName,
                    latitude: lat,
                    longitude: lng,
                    type: type
                ))
            }
        }
        currentElement = ""
    }
}

class IrishRailArrivalParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var arrivals: [IrishRailArrival] = []
    private var currentElement = ""
    private var fields: [String: String] = [:]

    init(data: Data) {
        self.data = data
    }

    func parse() -> [IrishRailArrival] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return arrivals
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "objStationData" {
            fields = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fields[currentElement, default: ""] += trimmed
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "objStationData" {
            arrivals.append(IrishRailArrival(
                trainCode: fields["Traincode"] ?? "",
                origin: fields["Origin"] ?? "",
                destination: fields["Destination"] ?? "",
                dueIn: Int(fields["Duein"] ?? "0") ?? 0,
                expectedArrival: fields["Exparrival"] ?? "",
                expectedDeparture: fields["Expdepart"] ?? "",
                status: fields["Status"] ?? "",
                direction: fields["Direction"] ?? "",
                trainType: fields["Traintype"] ?? "",
                lastLocation: fields["Lastlocation"] ?? ""
            ))
        }
        currentElement = ""
    }
}
