import Foundation
import CoreLocation

/// Lazily parses individual shapes from the cached GTFS ZIP.
/// Only loads the ONE requested shape, not all 2M+ shape points.
actor GTFSShapeService {
    static let shared = GTFSShapeService()

    /// Small cache for recently viewed shapes (max 5 to limit memory)
    private var shapeCache: [String: [CLLocationCoordinate2D]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheSize = 5

    /// Get the coordinates for a shape ID. Parses ONLY this shape from shapes.txt.
    func shapeCoordinates(for shapeId: String) async -> [CLLocationCoordinate2D]? {
        if let cached = shapeCache[shapeId] {
            return cached
        }

        guard let coords = await parseShapeFromZip(shapeId: shapeId), !coords.isEmpty else {
            return nil
        }

        // Cache with LRU eviction
        shapeCache[shapeId] = coords
        cacheOrder.append(shapeId)
        if cacheOrder.count > maxCacheSize {
            let evicted = cacheOrder.removeFirst()
            shapeCache.removeValue(forKey: evicted)
        }

        return coords
    }

    /// Get shape coordinates for a route by looking up any trip on that route.
    func shapeCoordinates(forRouteId routeId: String) async -> [CLLocationCoordinate2D]? {
        guard let trip = await GTFSScheduleService.shared.anyTripForRoute(routeId: routeId) else {
            return nil
        }
        return await shapeCoordinates(for: trip.shapeId)
    }

    /// Get shape coordinates for a specific trip.
    func shapeCoordinates(forTripId tripId: String) async -> [CLLocationCoordinate2D]? {
        guard let shapeId = await GTFSScheduleService.shared.shapeId(forTripId: tripId) else {
            return nil
        }
        return await shapeCoordinates(for: shapeId)
    }

    /// Clear cache to free memory
    func clearCache() {
        shapeCache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - Single-Shape Parsing

    /// Parse ONLY the matching shape_id from shapes.txt, skipping everything else.
    /// This reads the file line by line instead of loading all 2M+ points into memory.
    private func parseShapeFromZip(shapeId: String) async -> [CLLocationCoordinate2D]? {
        let zipURL = GTFSStopLoader.cachedZipURL
        guard let zipData = try? Data(contentsOf: zipURL) else {
            await APILogger.shared.log(
                service: "TFI", endpoint: "shapes.txt",
                status: .failure, durationMs: 0, detail: "No cached GTFS ZIP"
            )
            return nil
        }

        let start = Date()
        let loader = GTFSStopLoader()
        guard let csv = await loader.extractFile(from: zipData, named: "shapes.txt") else {
            return nil
        }

        // Parse header
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else { return nil }
        let headers = header.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let idIdx = headers.firstIndex(of: "shape_id"),
              let latIdx = headers.firstIndex(of: "shape_pt_lat"),
              let lonIdx = headers.firstIndex(of: "shape_pt_lon"),
              let seqIdx = headers.firstIndex(of: "shape_pt_sequence") else { return nil }

        let maxIdx = max(idIdx, latIdx, lonIdx, seqIdx)

        // Collect only matching entries
        var points: [(lat: Double, lon: Double, seq: Int)] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > maxIdx else { continue }

            // Skip non-matching shapes (this is the key optimization)
            guard fields[idIdx] == shapeId else { continue }

            guard let lat = Double(fields[latIdx]),
                  let lon = Double(fields[lonIdx]),
                  let seq = Int(fields[seqIdx]) else { continue }

            points.append((lat, lon, seq))
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if !points.isEmpty {
            await APILogger.shared.log(
                service: "TFI", endpoint: "shape/\(shapeId)",
                status: .success, durationMs: ms,
                detail: "\(points.count) points"
            )
        }

        return points
            .sorted { $0.seq < $1.seq }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}
