import Foundation
import CoreLocation

/// Queries route shapes from the SQLite database (indexed, ~10ms per shape).
/// Previously extracted shapes.txt from ZIP on every request (~5-10 seconds).
actor GTFSShapeService {
    static let shared = GTFSShapeService()

    /// Small LRU cache for recently viewed shapes
    private var shapeCache: [String: [CLLocationCoordinate2D]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheSize = 5

    /// Get the coordinates for a shape ID from SQLite.
    func shapeCoordinates(for shapeId: String) async -> [CLLocationCoordinate2D]? {
        if let cached = shapeCache[shapeId] {
            return cached
        }

        // Ensure database is ready
        await GTFSScheduleService.shared.loadIfNeeded()

        let coords = await GTFSScheduleService.shared.shapeCoordinates(for: shapeId)
        guard !coords.isEmpty else { return nil }

        // LRU cache
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

    func clearCache() {
        shapeCache.removeAll()
        cacheOrder.removeAll()
    }
}
