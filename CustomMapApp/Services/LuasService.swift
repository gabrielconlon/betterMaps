import Foundation

// MARK: - Luas Models

struct LuasStop: Identifiable {
    let id: String           // Abbreviation (e.g., "STI", "RAN", "HEU")
    let name: String
    let line: LuasLine

    enum LuasLine: String {
        case red = "Red"
        case green = "Green"

        var color: String {
            switch self {
            case .red: return "#FF3B30"
            case .green: return "#34C759"
            }
        }
    }
}

struct LuasForecast: Identifiable {
    let id = UUID()
    let direction: String    // "Inbound" or "Outbound"
    let destination: String
    let dueIn: String        // "5" (minutes), "DUE", or "No trams forecast"
    let dueMinutes: Int?     // nil if "DUE" or no service
}

struct LuasStopForecast {
    let stopName: String
    let message: String      // Service message if any
    let inbound: [LuasForecast]
    let outbound: [LuasForecast]

    var allForecasts: [LuasForecast] {
        inbound + outbound
    }
}

// MARK: - Luas Service

actor LuasService {
    private let baseURL = "https://luasforecasts.rpa.ie/xml/get.ashx"

    /// Fetch real-time forecast for a Luas stop
    func fetchForecast(stopCode: String) async -> LuasStopForecast? {
        let endpoint = "\(baseURL)?action=forecast&stop=\(stopCode)&encrypt=false"
        guard let url = URL(string: endpoint) else { return nil }
        let start = Date()

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let parser = LuasForecastParser(data: data)
            let forecast = parser.parse()
            await APILogger.shared.log(service: "Luas", endpoint: "forecast/\(stopCode)", status: .success, durationMs: ms)
            return forecast
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.log(service: "Luas", endpoint: "forecast/\(stopCode)", status: .failure, durationMs: ms, detail: error.localizedDescription)
            return nil
        }
    }

    /// Known Luas stops (hardcoded since there's no stops API)
    static let stops: [LuasStop] = [
        // Red Line
        LuasStop(id: "TPT", name: "The Point", line: .red),
        LuasStop(id: "SDK", name: "Spencer Dock", line: .red),
        LuasStop(id: "MYS", name: "Mayor Square - NCI", line: .red),
        LuasStop(id: "GDK", name: "George's Dock", line: .red),
        LuasStop(id: "CON", name: "Connolly", line: .red),
        LuasStop(id: "BUS", name: "Busáras", line: .red),
        LuasStop(id: "ABB", name: "Abbey Street", line: .red),
        LuasStop(id: "JER", name: "Jervis", line: .red),
        LuasStop(id: "FOU", name: "Four Courts", line: .red),
        LuasStop(id: "SMI", name: "Smithfield", line: .red),
        LuasStop(id: "MUS", name: "Museum", line: .red),
        LuasStop(id: "HEU", name: "Heuston", line: .red),
        LuasStop(id: "JAM", name: "James's", line: .red),
        LuasStop(id: "FAT", name: "Fatima", line: .red),
        LuasStop(id: "RIA", name: "Rialto", line: .red),
        LuasStop(id: "SUI", name: "Suir Road", line: .red),
        LuasStop(id: "GOL", name: "Goldenbridge", line: .red),
        LuasStop(id: "DRI", name: "Drimnagh", line: .red),
        LuasStop(id: "BLA", name: "Blackhorse", line: .red),
        LuasStop(id: "BLU", name: "Bluebell", line: .red),
        LuasStop(id: "KYL", name: "Kylemore", line: .red),
        LuasStop(id: "RED", name: "Red Cow", line: .red),
        LuasStop(id: "KIN", name: "Kingswood", line: .red),
        LuasStop(id: "BEL", name: "Belgard", line: .red),
        LuasStop(id: "COO", name: "Cookstown", line: .red),
        LuasStop(id: "HOS", name: "Hospital", line: .red),
        LuasStop(id: "TAL", name: "Tallaght", line: .red),
        LuasStop(id: "FET", name: "Fettercairn", line: .red),
        LuasStop(id: "CVN", name: "Cheeverstown", line: .red),
        LuasStop(id: "CIT", name: "Citywest Campus", line: .red),
        LuasStop(id: "FOR", name: "Fortunestown", line: .red),
        LuasStop(id: "SAG", name: "Saggart", line: .red),

        // Green Line
        LuasStop(id: "BRO", name: "Broombridge", line: .green),
        LuasStop(id: "CAB", name: "Cabra", line: .green),
        LuasStop(id: "PHI", name: "Phibsborough", line: .green),
        LuasStop(id: "GRA", name: "Grangegorman", line: .green),
        LuasStop(id: "BRD", name: "Broadstone - DIT", line: .green),
        LuasStop(id: "DOM", name: "Dominick", line: .green),
        LuasStop(id: "PAR", name: "Parnell", line: .green),
        LuasStop(id: "OUP", name: "O'Connell Upper", line: .green),
        LuasStop(id: "OGP", name: "O'Connell GPO", line: .green),
        LuasStop(id: "MAR", name: "Marlborough", line: .green),
        LuasStop(id: "WES", name: "Westmoreland", line: .green),
        LuasStop(id: "TRI", name: "Trinity", line: .green),
        LuasStop(id: "DAW", name: "Dawson", line: .green),
        LuasStop(id: "STS", name: "St. Stephen's Green", line: .green),
        LuasStop(id: "HAR", name: "Harcourt", line: .green),
        LuasStop(id: "CHA", name: "Charlemont", line: .green),
        LuasStop(id: "RAN", name: "Ranelagh", line: .green),
        LuasStop(id: "BEE", name: "Beechwood", line: .green),
        LuasStop(id: "COW", name: "Cowper", line: .green),
        LuasStop(id: "MIL", name: "Milltown", line: .green),
        LuasStop(id: "WIN", name: "Windy Arbour", line: .green),
        LuasStop(id: "DUN", name: "Dundrum", line: .green),
        LuasStop(id: "BAL", name: "Balally", line: .green),
        LuasStop(id: "KIL", name: "Kilmacud", line: .green),
        LuasStop(id: "STI", name: "Stillorgan", line: .green),
        LuasStop(id: "SAN", name: "Sandyford", line: .green),
        LuasStop(id: "CPK", name: "Central Park", line: .green),
        LuasStop(id: "GLE", name: "Glencairn", line: .green),
        LuasStop(id: "GAL", name: "The Gallops", line: .green),
        LuasStop(id: "LEO", name: "Leopardstown Valley", line: .green),
        LuasStop(id: "BAW", name: "Ballyogan Wood", line: .green),
        LuasStop(id: "CAR", name: "Carrickmines", line: .green),
        LuasStop(id: "LAU", name: "Laughanstown", line: .green),
        LuasStop(id: "CHE", name: "Cherrywood", line: .green),
        LuasStop(id: "BRI", name: "Bride's Glen", line: .green),
    ]
}

// MARK: - XML Parser

class LuasForecastParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var stopName = ""
    private var message = ""
    private var inbound: [LuasForecast] = []
    private var outbound: [LuasForecast] = []
    private var currentElement = ""
    private var currentDirection = ""
    private var currentDestination = ""
    private var currentDueIn = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> LuasStopForecast {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return LuasStopForecast(
            stopName: stopName,
            message: message,
            inbound: inbound,
            outbound: outbound
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "stopInfo" {
            stopName = attributes["stop"] ?? ""
        } else if elementName == "message" {
            // message content comes in foundCharacters
        } else if elementName == "direction" {
            currentDirection = attributes["name"] ?? ""
        } else if elementName == "tram" {
            currentDestination = attributes["destination"] ?? ""
            currentDueIn = attributes["dueMins"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "message" {
            message += string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "tram" {
            let minutes: Int? = currentDueIn == "DUE" ? 0 : Int(currentDueIn)
            let forecast = LuasForecast(
                direction: currentDirection,
                destination: currentDestination,
                dueIn: currentDueIn.isEmpty ? "No service" : (currentDueIn == "DUE" ? "DUE" : "\(currentDueIn) min"),
                dueMinutes: minutes
            )
            if currentDirection.lowercased().contains("inbound") {
                inbound.append(forecast)
            } else {
                outbound.append(forecast)
            }
        }
        currentElement = ""
    }
}
