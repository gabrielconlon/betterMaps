import Foundation
import CoreLocation
import Compression

// MARK: - Transit Stop Model

struct TransitStop: Identifiable {
    let id: String          // stop_id from GTFS
    let name: String
    let latitude: Double
    let longitude: Double
    let type: TransitStopType

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum TransitStopType: String {
        case bus = "bus"
        case luas = "luas"
        case dart = "dart"
        case rail = "rail"
        case suburban = "suburban"

        var displayName: String {
            switch self {
            case .bus: return "Bus"
            case .luas: return "Luas"
            case .dart: return "DART"
            case .rail: return "Rail"
            case .suburban: return "Suburban Rail"
            }
        }

        var systemImage: String {
            switch self {
            case .bus: return "bus.fill"
            case .luas: return "tram.fill"
            case .dart, .rail, .suburban: return "tram.fill"
            }
        }

        var colorHex: String {
            switch self {
            case .bus: return "#007AFF"
            case .luas: return "#34C759"
            case .dart: return "#FF9500"
            case .rail: return "#AF52DE"
            case .suburban: return "#FF2D55"
            }
        }
    }
}

// MARK: - GTFS Stop Loader

/// Downloads and parses the NTA GTFS static feed to extract all transit stops.
/// Caches locally so we don't re-download every launch.
actor GTFSStopLoader {
    private let cacheFileName = "gtfs_stops_cache.json"
    private let routesCacheFileName = "gtfs_routes_cache.json"
    private let cacheMaxAge: TimeInterval = 7 * 24 * 3600 // 7 days

    /// Route ID → route short name mapping (e.g., "125593" → "39A")
    /// Shared so LiveVehicleService can look up route names
    nonisolated(unsafe) static var routeNameLookup: [String: String] = [:]

    /// Path to the cached raw GTFS ZIP (for lazy shapes.txt extraction)
    static var cachedZipURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gtfs_all_cache.zip")
    }

    /// Cache the raw GTFS ZIP data to disk
    static func cacheRawZip(_ data: Data) {
        try? data.write(to: cachedZipURL)
    }

    /// Check if cached ZIP exists and is fresh
    static var hasCachedZip: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cachedZipURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modDate) < 7 * 24 * 3600
    }

    /// Load stops — from cache if fresh, otherwise download from NTA
    func loadStops() async -> [TransitStop] {
        // Check cache first
        if let cached = loadFromCache() {
            await APILogger.shared.log(service: "NTA", endpoint: "GTFS stops (cached)", status: .cached, durationMs: 0)
            return cached
        }

        // Download fresh — static GTFS is open data, no API key needed
        let stops = await downloadAndParseGTFS()
        if !stops.isEmpty {
            saveToCache(stops)
        }
        if GTFSStopLoader.routeNameLookup.isEmpty {
            await APILogger.shared.log(service: "TFI", endpoint: "GTFS route lookup", status: .failure, durationMs: 0, detail: "routeNameLookup is empty after GTFS load")
        }
        return stops.isEmpty ? builtInStops() : stops
    }

    // MARK: - Download GTFS

    private func downloadAndParseGTFS() async -> [TransitStop] {
        // Static GTFS feed is open data — no API key needed
        // Try TFI open data URL first, fallback to data.gov.ie
        let urls = [
            "https://www.transportforireland.ie/transitData/Data/GTFS_All.zip",
            "https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            if let stops = await tryDownloadGTFS(url: url) {
                return stops
            }
        }
        return []
    }

    private func tryDownloadGTFS(url: URL) async -> [TransitStop]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60 // Large file, give it time

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if httpStatus != 200 {
                await APILogger.shared.log(service: "TFI", endpoint: "GTFS static (\(url.host ?? ""))", status: .failure, durationMs: ms, detail: "HTTP \(httpStatus)")
                return nil
            }

            await APILogger.shared.log(service: "TFI", endpoint: "GTFS static (\(data.count / 1024)KB)", status: .success, durationMs: ms)
            await APILogger.shared.trackBytes(data.count)

            // Cache the raw ZIP for lazy shapes.txt extraction later
            Self.cacheRawZip(data)

            let stops = parseStopsFromZip(data: data)
            // Also parse routes.txt for route name lookup
            await parseRoutesFromZip(data: data)
            return stops.isEmpty ? nil : stops
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.log(service: "TFI", endpoint: "GTFS static", status: .failure, durationMs: ms, detail: error.localizedDescription)
            return nil
        }
    }

    /// Parse routes.txt to build route_id → route_short_name lookup
    private func parseRoutesFromZip(data: Data) async {
        guard let routesCSV = extractFileFromZip(data: data, fileName: "routes.txt") else {
            await APILogger.shared.log(service: "TFI", endpoint: "routes.txt", status: .failure, durationMs: 0, detail: "routes.txt not found or empty in ZIP")
            return
        }
        let lines = routesCSV.components(separatedBy: .newlines)
        guard let headerLine = lines.first else {
            await APILogger.shared.log(service: "TFI", endpoint: "routes.txt", status: .failure, durationMs: 0, detail: "routes.txt not found or empty in ZIP")
            return
        }
        let headers = parseCSVRow(headerLine)
        guard let idIdx = headers.firstIndex(of: "route_id"),
              let nameIdx = headers.firstIndex(of: "route_short_name") else {
            await APILogger.shared.log(service: "TFI", endpoint: "routes.txt", status: .failure, durationMs: 0, detail: "routes.txt not found or empty in ZIP")
            return
        }

        var lookup: [String: String] = [:]
        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(idIdx, nameIdx) else { continue }
            let routeId = fields[idIdx]
            let shortName = fields[nameIdx]
            if !routeId.isEmpty && !shortName.isEmpty {
                lookup[routeId] = shortName
            }
        }
        GTFSStopLoader.routeNameLookup = lookup

        if lookup.isEmpty {
            await APILogger.shared.log(service: "TFI", endpoint: "routes.txt", status: .failure, durationMs: 0, detail: "routes.txt not found or empty in ZIP")
        } else {
            await APILogger.shared.log(service: "TFI", endpoint: "routes.txt (\(lookup.count) routes)", status: .success, durationMs: 0)
        }

        // Cache the routes lookup
        if let data = try? JSONEncoder().encode(lookup) {
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(routesCacheFileName)
            try? data.write(to: url)
        }
    }

    /// Load cached route name lookup (call on app launch)
    static func loadCachedRouteNames() {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gtfs_routes_cache.json")
        if let data = try? Data(contentsOf: url),
           let lookup = try? JSONDecoder().decode([String: String].self, from: data) {
            routeNameLookup = lookup
        }
        print("GTFS route lookup: \(routeNameLookup.count) routes loaded from cache")
        // Also log to API Logs so it's visible in-app
        Task { @MainActor in
            APILogger.shared.log(
                service: "TFI",
                endpoint: "Route name cache",
                status: routeNameLookup.isEmpty ? .failure : .success,
                durationMs: 0,
                detail: "\(routeNameLookup.count) route names loaded"
            )
        }
    }

    /// Parse stops.txt from GTFS ZIP data
    private func parseStopsFromZip(data: Data) -> [TransitStop] {
        // Simple ZIP extraction — look for stops.txt in the archive
        // GTFS ZIPs use standard ZIP format. We extract the stops.txt entry.

        guard let stopsCSV = extractFileFromZip(data: data, fileName: "stops.txt") else {
            return []
        }

        return parseStopsCSV(stopsCSV)
    }

    private func parseStopsCSV(_ csv: String) -> [TransitStop] {
        let lines = csv.components(separatedBy: .newlines)
        guard let headerLine = lines.first else { return [] }

        // Parse CSV header to find column indices
        let headers = parseCSVRow(headerLine)
        guard let idIdx = headers.firstIndex(of: "stop_id"),
              let nameIdx = headers.firstIndex(of: "stop_name"),
              let latIdx = headers.firstIndex(of: "stop_lat"),
              let lonIdx = headers.firstIndex(of: "stop_lon") else {
            return []
        }

        var stops: [TransitStop] = []

        for line in lines.dropFirst() {
            let fields = parseCSVRow(line)
            guard fields.count > max(idIdx, nameIdx, latIdx, lonIdx),
                  let lat = Double(fields[latIdx]),
                  let lon = Double(fields[lonIdx]),
                  lat != 0, lon != 0 else { continue }

            let stopId = fields[idIdx]
            let name = fields[nameIdx]
            let type = classifyStop(id: stopId, name: name)

            stops.append(TransitStop(
                id: stopId,
                name: name,
                latitude: lat,
                longitude: lon,
                type: type
            ))
        }

        return stops
    }

    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in row {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// Known DART station name keywords (coastal + DART+ western line)
    private static let dartStationNames: Set<String> = [
        // Coastal line
        "malahide", "portmarnock", "clongriffin", "howth", "howth junction",
        "sutton", "bayside", "kilbarrack", "raheny", "harmonstown",
        "killester", "clontarf road", "connolly", "tara street", "pearse",
        "grand canal dock", "lansdowne road", "sandymount", "sydney parade",
        "booterstown", "blackrock", "seapoint", "salthill", "monkstown",
        "dún laoghaire", "dun laoghaire", "sandycove", "glenageary",
        "dalkey", "killiney", "shankill", "bray", "greystones",
        // DART+ western line (Maynooth direction)
        "broombridge", "drumcondra", "ashtown", "navan road",
        "castleknock", "coolmine", "clonsilla", "leixlip",
        "maynooth", "m3 parkway", "dunboyne",
        // DART+ south-western (Kildare direction)
        "park west", "cherry orchard", "clondalkin", "hazelhatch",
        "adamstown", "kishoge"
    ]

    /// Classify a stop as bus/luas/dart/rail based on ID patterns and name
    private func classifyStop(id: String, name: String) -> TransitStop.TransitStopType {
        let lowerId = id.lowercased()
        let lowerName = name.lowercased()

        if lowerId.hasPrefix("luas") || lowerName.contains("luas") {
            return .luas
        }
        // Check known DART station names (don't use generic "dart" substring — catches Dartmouth, Dartry, etc.)
        if Self.dartStationNames.contains(where: { lowerName.contains($0) }) {
            return .dart
        }
        if lowerId.hasPrefix("ir_") || lowerId.hasPrefix("rail") ||
           lowerName.contains("station") && (lowerName.contains("train") || lowerName.contains("rail")) {
            return .rail
        }
        return .bus
    }

    // MARK: - ZIP Extraction

    /// Extract a single file from a ZIP archive using Compression framework
    func extractFileFromZip(data: Data, fileName: String) -> String? {
        // ZIP local file header signature
        let sig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        var offset = 0

        while offset + 30 < data.count {
            let headerBytes = [UInt8](data[offset..<offset+4])
            guard headerBytes == sig else { break }

            let compressionMethod = readUInt16(data, at: offset + 8)
            let compressedSize = readUInt32(data, at: offset + 18)
            let uncompressedSize = readUInt32(data, at: offset + 22)
            let nameLength = readUInt16(data, at: offset + 26)
            let extraLength = readUInt16(data, at: offset + 28)

            let nameStart = offset + 30
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { break }

            let entryName = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
            let dataStart = nameEnd + Int(extraLength)

            if entryName == fileName || entryName.hasSuffix("/\(fileName)") {
                if compressionMethod == 0 {
                    // Stored (uncompressed)
                    let dataEnd = dataStart + Int(uncompressedSize)
                    guard dataEnd <= data.count else { return nil }
                    return String(data: data[dataStart..<dataEnd], encoding: .utf8)
                } else if compressionMethod == 8 {
                    // Deflate — use Compression framework with raw deflate
                    let dataEnd = dataStart + Int(compressedSize)
                    guard dataEnd <= data.count else { return nil }
                    let compressed = data[dataStart..<dataEnd]

                    // Raw deflate decompression using Compression framework
                    let decompressed = decompressRawDeflate(
                        compressed: compressed,
                        expectedSize: Int(uncompressedSize)
                    )
                    if let decompressed {
                        return String(data: decompressed, encoding: .utf8)
                    }
                    return nil
                }
            }

            offset = nameEnd + Int(extraLength) + Int(compressedSize)
        }
        return nil
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    /// Decompress raw deflate data (no zlib/gzip headers)
    private func decompressRawDeflate(compressed: Data, expectedSize: Int) -> Data? {
        // Add a zlib header (78 01) to make it valid zlib so NSData can decompress
        var zlibData = Data([0x78, 0x01]) // zlib header: CM=8, CINFO=7, no dict, FLEVEL=0
        zlibData.append(compressed)

        // Add Adler-32 checksum placeholder (required by zlib format)
        // Use 0 — decompressor may or may not validate
        zlibData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        if let decompressed = try? (zlibData as NSData).decompressed(using: .zlib) {
            return decompressed as Data
        }

        // Fallback: try with Compression framework directly
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = compressed.withUnsafeBytes { srcPtr -> Int in
            guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, expectedSize,
                srcBase, compressed.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    // MARK: - Cache

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFileName)
    }

    private func loadFromCache() -> [TransitStop]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }

        // Check age
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > cacheMaxAge {
            return nil // expired
        }

        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([CachedTransitStop].self, from: data) else {
            return nil
        }

        return cached.map { TransitStop(id: $0.id, name: $0.name, latitude: $0.lat, longitude: $0.lon, type: TransitStop.TransitStopType(rawValue: $0.type) ?? .bus) }
    }

    private func saveToCache(_ stops: [TransitStop]) {
        let cacheable = stops.map { CachedTransitStop(id: $0.id, name: $0.name, lat: $0.latitude, lon: $0.longitude, type: $0.type.rawValue) }
        if let data = try? JSONEncoder().encode(cacheable) {
            try? data.write(to: cacheURL)
        }
    }

    // MARK: - Built-in stops (fallback when no NTA key)

    private func builtInStops() -> [TransitStop] {
        var stops: [TransitStop] = []

        // Luas stops with approximate coordinates
        let luasStops = LuasService.stops
        // We don't have coordinates for Luas from the basic API,
        // so these will be populated when GTFS feed is available
        // For now, return Irish Rail stations which DO have coordinates

        return stops
    }
}

// MARK: - Codable cache model

private struct CachedTransitStop: Codable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let type: String
}
