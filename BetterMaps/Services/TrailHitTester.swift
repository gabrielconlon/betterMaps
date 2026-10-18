import Foundation
import CoreGraphics
import CoreLocation
import MapKit
import SwiftUI

/// Screen-space hit testing for trail polylines. A tap selects the trail
/// whose nearest segment lies within `tolerance` points of the tap; when
/// several qualify the closest wins.
enum TrailHitTester {

    /// Default tap tolerance: half of a 44 pt touch target.
    static let defaultTolerance: CGFloat = 22

    /// Returns the id of the trail nearest to `tap`, or nil when none is
    /// within `tolerance`. Each trail is a list of polylines in screen space.
    /// A one-point polyline is treated as a dot; empty ones are ignored.
    static func hit(tap: CGPoint,
                    trails: [(id: UUID, screenPoints: [[CGPoint]])],
                    tolerance: CGFloat = defaultTolerance) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for trail in trails {
            guard let d = distance(from: tap, toPolylines: trail.screenPoints), d <= tolerance else { continue }
            if best == nil || d < best!.distance {
                best = (trail.id, d)
            }
        }
        return best?.id
    }

    /// Smallest distance from `p` to any segment of `polylines`, or nil when
    /// there are no points at all.
    static func distance(from p: CGPoint, toPolylines polylines: [[CGPoint]]) -> CGFloat? {
        var best: CGFloat?
        for line in polylines {
            guard let first = line.first else { continue }
            if line.count == 1 {
                let d = hypot(p.x - first.x, p.y - first.y)
                best = min(best ?? d, d)
                continue
            }
            for i in 0..<(line.count - 1) {
                let d = distance(from: p, toSegment: line[i], line[i + 1])
                best = min(best ?? d, d)
            }
        }
        return best
    }

    /// Distance from `p` to the segment `a`–`b`, clamped to its endpoints.
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Projects trails into the map's local coordinate space so `hit` can
    /// run on them. When `coordinate` (the tap) is given, only trails whose
    /// bbox — expanded by `tolerance` worth of degrees at the current zoom,
    /// plus 10% — contains it are projected, so a tap costs a handful of
    /// conversions instead of one per vertex on screen.
    @MainActor
    static func project(_ trails: [TrailLite],
                        using proxy: MapProxy,
                        bboxContaining coordinate: CLLocationCoordinate2D?,
                        tolerance: CGFloat = defaultTolerance) -> [(id: UUID, screenPoints: [[CGPoint]])] {
        var padLat = 0.0
        var padLon = 0.0
        if let coordinate,
           let tapPoint = proxy.convert(coordinate, to: .local),
           let offset = proxy.convert(CGPoint(x: tapPoint.x + tolerance, y: tapPoint.y + tolerance), from: .local) {
            padLat = abs(offset.latitude - coordinate.latitude)
            padLon = abs(offset.longitude - coordinate.longitude)
        }

        var out: [(id: UUID, screenPoints: [[CGPoint]])] = []
        for trail in trails {
            if let c = coordinate {
                let box = trail.bbox
                let latPad = padLat + (box.maxLat - box.minLat) * 0.1
                let lonPad = padLon + (box.maxLon - box.minLon) * 0.1
                guard c.latitude >= box.minLat - latPad, c.latitude <= box.maxLat + latPad,
                      c.longitude >= box.minLon - lonPad, c.longitude <= box.maxLon + lonPad
                else { continue }
            }
            let lines: [[CGPoint]] = trail.segments.map { segment in
                segment.coordinates.compactMap { proxy.convert($0, to: .local) }
            }
            out.append((trail.id, lines))
        }
        return out
    }
}
