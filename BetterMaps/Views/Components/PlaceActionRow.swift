import SwiftUI
import MapKit

/// The single action row on a place or POI card: public transport
/// directions, one primary action (Add to layer / Edit), Share, and an
/// optional extra (e.g. transit arrivals). Each tile is at least 52pt tall.
struct PlaceActionRow: View {
    struct Extra {
        let title: String
        let systemImage: String
        let action: () -> Void
    }

    let name: String
    let coordinate: CLLocationCoordinate2D
    let primaryTitle: String
    let primarySystemImage: String
    let onPrimary: () -> Void
    /// Opens the directions sheet for this place.
    let onDirections: () -> Void
    var extra: Extra? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onDirections) {
                tile("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill", prominent: true)
            }
            .accessibilityLabel("Directions")
            .accessibilityHint("Plans a public transport journey")

            Button(action: onPrimary) {
                tile(primaryTitle, systemImage: primarySystemImage, prominent: false)
            }

            if let extra {
                Button(action: extra.action) {
                    tile(extra.title, systemImage: extra.systemImage, prominent: false)
                }
            }

            ShareLink(item: shareURL, subject: Text(name), message: Text(name)) {
                tile("Share", systemImage: "square.and.arrow.up", prominent: false)
            }
        }
        .buttonStyle(.plain)
    }

    private func tile(_ title: String, systemImage: String, prominent: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Apple Maps link that opens on this spot with the place's name.
    var shareURL: URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components.url ?? URL(string: "https://maps.apple.com/")!
    }

    /// Hand off to Apple Maps with walking directions (the fallback when
    /// our own planner finds nothing).
    static func openInAppleMaps(name: String, coordinate: CLLocationCoordinate2D) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
