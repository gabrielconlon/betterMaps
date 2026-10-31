import CoreGraphics
import MapKit

/// Where to put the camera when a directions search shows on the map: the
/// smallest map rect, at the map view's own aspect ratio, that puts every
/// point (both ends, and the routes when there are any) inside the part of
/// the map the sheet and the top controls leave uncovered. Starting
/// directions used to leave the camera wherever it was, so the start or
/// the destination was often off screen (Gabe, 2026-10-31).
enum DirectionsCamera {
    /// Space kept clear around the content, in screen points.
    struct Insets: Equatable {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat
    }

    /// Smallest span shown, in metres, so a journey to the next street over
    /// does not zoom to the doorstep.
    static let minimumSpanMeters: Double = 600

    /// The rect to hand `MapCameraPosition.rect`, or nil when there is
    /// nothing to fit or no room left to fit it in. The rect has the map's
    /// aspect ratio, so MapKit shows it exactly and the content's centre
    /// lands in the middle of the uncovered area rather than the screen's.
    static func rect(fitting coordinates: [CLLocationCoordinate2D],
                     mapSize: CGSize,
                     insets: Insets) -> MKMapRect? {
        let valid = coordinates.filter(CLLocationCoordinate2DIsValid)
        guard !valid.isEmpty, mapSize.width > 0, mapSize.height > 0 else { return nil }
        let availableWidth = mapSize.width - insets.leading - insets.trailing
        let availableHeight = mapSize.height - insets.top - insets.bottom
        guard availableWidth > 40, availableHeight > 40 else { return nil }

        let points = valid.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let midLatitude = (valid.map(\.latitude).min()! + valid.map(\.latitude).max()!) / 2
        let minSpan = MKMapPointsPerMeterAtLatitude(midLatitude) * minimumSpanMeters
        let width = max(maxX - minX, minSpan)
        let height = max(maxY - minY, minSpan)

        // Map points per screen point: whichever axis is tighter decides.
        let scale = max(width / availableWidth, height / availableHeight)
        let centreX = (minX + maxX) / 2
        let centreY = (minY + maxY) / 2
        return MKMapRect(x: centreX - (insets.leading + availableWidth / 2) * scale,
                         y: centreY - (insets.top + availableHeight / 2) * scale,
                         width: mapSize.width * scale,
                         height: mapSize.height * scale)
    }
}
