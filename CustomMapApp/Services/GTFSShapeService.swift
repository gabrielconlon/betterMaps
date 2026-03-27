import Foundation
import CoreLocation

/// Lazily parses shapes.txt from the cached GTFS ZIP to get route geometry.
/// Shapes are loaded on demand when a user taps a route, not at startup.
actor GTFSShapeService {
    static let shared = GTFSShapeService()

    /// Cached parsed shapes: shape_id → ordered array of coordinates
    private var shapeCache: [String: [CLLocationCoordinate2D]] = [:]

    /// All shapes parsed from shapes.txt (loaded once on first request)
    private var allShapes: [String: [ShapePoint]]?

    private struct ShapePoint {
        let latitude: Double
        let longitude: Double
        let sequence: Int
    }

    /// Get the coordinates for a shape ID. Parses shapes.txt from cached ZIP on first call.
    func shapeCoordinates(for shapeId: String) async -> [CLLocationCoordinate2D]? {
        // Check memory cache first
        if let cached = shapeCache[shapeId] {
            return cached
        }

        // Ensure shapes are loaded
        if allShapes == nil {
            await loadShapes()
        }

        guard let points = allShapes?[shapeId] else { return nil }

        let coords = points
            .sorted { $0.sequence < $1.sequence }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        // Cache for future lookups
        shapeCache[shapeId] = coords
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

    // MARK: - Parsing

    /// Parse shapes.txt from the cached GTFS ZIP file.
    private func loadShapes() async {
        let zipURL = GTFSStopLoader.cachedZipURL
        guard let zipData = try? Data(contentsOf: zipURL) else {
            await APILogger.shared.log(
                service: "TFI", endpoint: "shapes.txt",
                status: .failure, durationMs: 0,
                detail: "No cached GTFS ZIP found"
            )
            allShapes = [:]
            return
        }

        let start = Date()
        let loader = GTFSStopLoader()
        guard let csv = await loader.extractFile(from: zipData, named: "shapes.txt") else {
            await APILogger.shared.log(
                service: "TFI", endpoint: "shapes.txt",
                status: .failure, durationMs: 0,
                detail: "shapes.txt not found in ZIP"
            )
            allShapes = [:]
            return
        }

        var shapes: [String: [ShapePoint]] = [:]
        let lines = csv.components(separatedBy: .newlines)
        guard let header = lines.first else {
            allShapes = [:]
            return
        }

        let headers = header.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let idIdx = headers.firstIndex(of: "shape_id"),
              let latIdx = headers.firstIndex(of: "shape_pt_lat"),
              let lonIdx = headers.firstIndex(of: "shape_pt_lon"),
              let seqIdx = headers.firstIndex(of: "shape_pt_sequence") else {
            allShapes = [:]
            return
        }

        let maxIdx = max(idIdx, latIdx, lonIdx, seqIdx)

        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > maxIdx else { continue }

            let shapeId = fields[idIdx]
            guard !shapeId.isEmpty,
                  let lat = Double(fields[latIdx]),
                  let lon = Double(fields[lonIdx]),
                  let seq = Int(fields[seqIdx]) else { continue }

            shapes[shapeId, default: []].append(ShapePoint(latitude: lat, longitude: lon, sequence: seq))
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        await APILogger.shared.log(
            service: "TFI", endpoint: "shapes.txt parsed",
            status: .success, durationMs: ms,
            detail: "\(shapes.count) shapes loaded"
        )

        allShapes = shapes
    }
}
