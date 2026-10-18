import Foundation
import CoreLocation

/// One editable waypoint in a `TrailDraft`.
struct TrailPoint: Sendable, Hashable, Identifiable, Codable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    /// User annotation: flagged points draw the start/end pin. Has no effect
    /// on which lines are drawn (order does).
    var isEndpoint: Bool

    init(id: UUID = UUID(), latitude: Double, longitude: Double, isEndpoint: Bool = false) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.isEndpoint = isEndpoint
    }

    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D, isEndpoint: Bool = false) {
        self.init(id: id, latitude: coordinate.latitude, longitude: coordinate.longitude, isEndpoint: isEndpoint)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// In-memory editing state for one trail. Pure value type: the editor view
/// owns one of these in `@State`, mutates it through the methods below, and
/// commits to SwiftData when the user taps Done.
///
/// Every mutation that should be undoable snapshots `points` first. A drag
/// is many `move` calls but one undo step, so the caller brackets it with
/// `beginMove()` (snapshot) and `move(_:to:)` (no snapshot).
struct TrailDraft: Sendable, Equatable, Codable {
    /// Maximum number of undo snapshots retained.
    static let undoLimit = 50
    /// Taps closer than this to an existing segment insert mid-line.
    static let insertionThresholdMeters = 30.0

    var points: [TrailPoint]
    var name: String
    var isSnapped: Bool
    /// Not persisted: a resumed draft starts with a fresh history.
    private(set) var undoStack: [[TrailPoint]] = []

    private enum CodingKeys: String, CodingKey {
        case points, name, isSnapped
    }

    init(points: [TrailPoint] = [], name: String = "", isSnapped: Bool = false) {
        self.points = points
        self.name = name
        self.isSnapped = isSnapped
        self.undoStack = []
    }

    // MARK: - Derived

    var canUndo: Bool { !undoStack.isEmpty }

    var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

    /// Straight-line length through the points in order (Haversine sum).
    var straightMeters: Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(points.count - 1) {
            total += WaypointGraph.meters(points[i].coordinate, points[i + 1].coordinate)
        }
        return total
    }

    // MARK: - Mutations

    /// Pushes an undo snapshot of the current points. Called by every
    /// undoable mutation; callers may invoke it directly to bracket a
    /// compound edit (e.g. `beginMove()` does).
    mutating func recordUndo() {
        undoStack.append(points)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    /// Adds a point. If the coordinate lies within
    /// `insertionThresholdMeters` of an existing segment the point is
    /// inserted into that segment so the line still passes through it in
    /// order; otherwise it is appended. The first point is auto-flagged as
    /// an endpoint.
    mutating func add(_ coordinate: CLLocationCoordinate2D) {
        recordUndo()
        let new = TrailPoint(coordinate: coordinate, isEndpoint: points.isEmpty)
        if let insertAt = Self.nearestSegmentInsertionIndex(points: points, coordinate: coordinate) {
            points.insert(new, at: insertAt)
        } else {
            points.append(new)
        }
    }

    /// Call once when a drag starts so the whole drag is a single undo step.
    mutating func beginMove() {
        recordUndo()
    }

    /// Live reposition during a drag. Does not record undo — see `beginMove()`.
    mutating func move(_ id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard let i = points.firstIndex(where: { $0.id == id }) else { return }
        points[i].latitude = coordinate.latitude
        points[i].longitude = coordinate.longitude
    }

    /// Call when a drag ends. Currently a no-op kept for symmetry so the
    /// editor can bracket drags without caring about the undo model.
    mutating func endMove() {}

    mutating func remove(_ id: UUID) {
        guard points.contains(where: { $0.id == id }) else { return }
        recordUndo()
        points.removeAll { $0.id == id }
    }

    mutating func toggleEndpoint(_ id: UUID) {
        guard let i = points.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        points[i].isEndpoint.toggle()
    }

    /// Restores the most recent snapshot. Returns false if there is nothing
    /// to undo.
    @discardableResult
    mutating func undo() -> Bool {
        guard let last = undoStack.popLast() else { return false }
        points = last
        return true
    }

    // MARK: - Geometry

    /// If `coordinate` is within `maxMeters` of any segment connecting two
    /// consecutive points, returns the index at which a new point should be
    /// inserted to land on that segment. Otherwise nil (caller appends).
    static func nearestSegmentInsertionIndex(points: [TrailPoint],
                                             coordinate: CLLocationCoordinate2D,
                                             maxMeters: Double = insertionThresholdMeters) -> Int? {
        guard points.count >= 2 else { return nil }
        var bestDistance = Double.infinity
        var bestInsertIndex: Int? = nil
        for i in 0..<(points.count - 1) {
            let d = distance(from: coordinate, toSegment: points[i].coordinate, points[i + 1].coordinate)
            if d < bestDistance {
                bestDistance = d
                bestInsertIndex = i + 1
            }
        }
        return bestDistance <= maxMeters ? bestInsertIndex : nil
    }

    /// Perpendicular distance in meters from `point` to the segment `a`–`b`,
    /// clamped to the segment's endpoints. Uses a flat-earth projection
    /// around `a`; at the tens-of-meters scale this is checked at, the
    /// curvature error is far below tap accuracy.
    static func distance(from point: CLLocationCoordinate2D,
                         toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> Double {
        let metersPerLat = 111_320.0
        let metersPerLon = 111_320.0 * cos(a.latitude * .pi / 180)

        let bx = (b.longitude - a.longitude) * metersPerLon
        let by = (b.latitude - a.latitude) * metersPerLat
        let px = (point.longitude - a.longitude) * metersPerLon
        let py = (point.latitude - a.latitude) * metersPerLat

        let lengthSq = bx * bx + by * by
        guard lengthSq > 0 else { return hypot(px, py) }
        var t = (px * bx + py * by) / lengthSq
        t = max(0, min(1, t))
        return hypot(px - t * bx, py - t * by)
    }
}

// MARK: - From SwiftData

extension TrailDraft {
    /// Builds a draft from a persisted trail and the candidate places. Only
    /// places whose `pathId` matches the trail are used, ordered by
    /// `sortIndex` then `createdAt` (the legacy tiebreak for data saved
    /// before sortIndex existed, where every sortIndex is 0).
    @MainActor
    init(trail: Trail, places: [Place]) {
        let members = places
            .filter { $0.pathId == trail.pathId }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
        self.init(
            points: members.map {
                TrailPoint(id: $0.id, latitude: $0.latitude, longitude: $0.longitude, isEndpoint: $0.isWaypointEndpoint)
            },
            name: trail.name,
            isSnapped: trail.isSnapped
        )
    }
}
