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
    var stopCode: String?   // Public-facing stop number (from GTFS stop_code)

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
        request.timeoutInterval = 300 // TFI server can be very slow for this ~65 MB file

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
        let codeIdx = headers.firstIndex(of: "stop_code")

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
            let code = codeIdx.flatMap { fields.count > $0 ? fields[$0] : nil }

            stops.append(TransitStop(
                id: stopId,
                name: name,
                latitude: lat,
                longitude: lon,
                type: type,
                stopCode: code?.isEmpty == true ? nil : code
            ))
        }

        return stops
    }

    private func parseCSVRow(_ row: String) -> [String] {
        // Strip BOM if present (common in CSV files, breaks header matching)
        let cleanRow = row.hasPrefix("\u{FEFF}") ? String(row.dropFirst()) : row
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in cleanRow {
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

    /// Initial stop classification based on ID/name patterns.
    /// This is a rough guess — stops are reclassified using actual GTFS route_type
    /// data after the schedule database loads (see MapTabView and RoutingViewModel).
    /// Only match when we're very confident to avoid false positives like
    /// bus stops named "Connolly Road" being tagged as DART.
    private func classifyStop(id: String, name: String) -> TransitStop.TransitStopType {
        let lowerId = id.lowercased()
        let lowerName = name.lowercased()

        // Only match Luas if explicitly in the ID or name
        if lowerId.hasPrefix("luas") || lowerName.contains("luas") {
            return .luas
        }
        // Only match rail if ID has a rail prefix or name explicitly says train/rail station
        if lowerId.hasPrefix("ir_") || lowerId.hasPrefix("rail") ||
           (lowerName.contains("station") && (lowerName.contains("train") || lowerName.contains("rail"))) {
            return .rail
        }
        // Default everything else to bus — reclassified later from database
        return .bus
    }

    // MARK: - ZIP Extraction

    /// Extract a single file from a ZIP archive using the central directory.
    /// The old sequential local-header approach broke when entries used "data descriptors"
    /// (bit 3 of general purpose flag), which sets compressedSize=0 in the local header.
    /// This caused the offset to the next entry to be wrong, skipping all subsequent files.
    /// The central directory at the end of the ZIP always has correct sizes.
    func extractFileFromZip(data: Data, fileName: String) -> String? {
        // Step 1: Find End of Central Directory record (PK\x05\x06)
        // Search backwards from end of data (EOCD is within last 65557 bytes)
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65557)
        for i in stride(from: data.count - 4, through: searchStart, by: -1) {
            if data[i] == 0x50 && data[i+1] == 0x4B && data[i+2] == 0x05 && data[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0, eocdOffset + 22 <= data.count else { return nil }

        // Step 2: Read central directory location
        let cdOffset = Int(readUInt32(data, at: eocdOffset + 16))
        let numEntries = Int(readUInt16(data, at: eocdOffset + 10))
        guard cdOffset >= 0, cdOffset < data.count else { return nil }

        // Step 3: Iterate central directory entries (PK\x01\x02)
        var offset = cdOffset
        for _ in 0..<numEntries {
            guard offset + 46 <= data.count,
                  data[offset] == 0x50, data[offset+1] == 0x4B,
                  data[offset+2] == 0x01, data[offset+3] == 0x02 else { break }

            let compressionMethod = readUInt16(data, at: offset + 10)
            let compressedSize = Int(readUInt32(data, at: offset + 20))
            let uncompressedSize = Int(readUInt32(data, at: offset + 24))
            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let localHeaderOffset = Int(readUInt32(data, at: offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { break }

            let entryName = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""

            // Advance to next central directory entry
            offset = nameEnd + extraLength + commentLength

            // Check if this is the file we want
            guard entryName == fileName || entryName.hasSuffix("/\(fileName)") else { continue }

            // Step 4: Read file data using the local header offset (accurate from central dir)
            guard localHeaderOffset + 30 <= data.count else { return nil }
            let localNameLen = Int(readUInt16(data, at: localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(data, at: localHeaderOffset + 28))
            let fileDataStart = localHeaderOffset + 30 + localNameLen + localExtraLen

            if compressionMethod == 0 {
                let fileDataEnd = fileDataStart + uncompressedSize
                guard fileDataEnd <= data.count else { return nil }
                return String(data: data[fileDataStart..<fileDataEnd], encoding: .utf8)
            } else if compressionMethod == 8 {
                let fileDataEnd = fileDataStart + compressedSize
                guard fileDataEnd <= data.count else { return nil }
                let compressed = data[fileDataStart..<fileDataEnd]
                return decompressRawDeflate(compressed: compressed, expectedSize: uncompressedSize)
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            return nil
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

        return cached.map { TransitStop(id: $0.id, name: $0.name, latitude: $0.lat, longitude: $0.lon, type: TransitStop.TransitStopType(rawValue: $0.type) ?? .bus, stopCode: $0.stopCode) }
    }

    private func saveToCache(_ stops: [TransitStop]) {
        let cacheable = stops.map { CachedTransitStop(id: $0.id, name: $0.name, lat: $0.latitude, lon: $0.longitude, type: $0.type.rawValue, stopCode: $0.stopCode) }
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
    var stopCode: String?
}
