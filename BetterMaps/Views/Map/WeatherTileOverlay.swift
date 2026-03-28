import SwiftUI
import MapKit

/// Overlay MKMapView that shows ONLY weather tiles (no base map).
/// Uses canReplaceMapContent=true so the tile overlay replaces the base map entirely,
/// then sits in a ZStack on top of the SwiftUI Map.
struct WeatherTileOverlayView: UIViewRepresentable {
    let activeOverlays: Set<WeatherOverlay>
    let apiKey: String
    @Binding var region: MKCoordinateRegion?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isUserInteractionEnabled = false
        mapView.showsUserLocation = false
        mapView.showsBuildings = false
        mapView.showsTraffic = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.backgroundColor = .clear
        mapView.isOpaque = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Sync region with the main SwiftUI Map
        if let region {
            let currentCenter = mapView.region.center
            let delta = abs(currentCenter.latitude - region.center.latitude) + abs(currentCenter.longitude - region.center.longitude)
            // Only update if region actually changed (avoids jitter)
            if delta > 0.0001 || abs(mapView.region.span.latitudeDelta - region.span.latitudeDelta) > 0.0001 {
                mapView.setRegion(region, animated: false)
            }
        }

        let currentTypes = Set(mapView.overlays.compactMap { ($0 as? WeatherMKTileOverlay)?.weatherType })
        let desired = activeOverlays

        // Remove overlays no longer active
        for overlay in mapView.overlays {
            if let weather = overlay as? WeatherMKTileOverlay, !desired.contains(weather.weatherType) {
                mapView.removeOverlay(overlay)
            }
        }

        // Add new overlays
        for type in desired where !currentTypes.contains(type) {
            let template = "https://tile.openweathermap.org/map/\(type.rawValue)/{z}/{x}/{y}.png?appid=\(apiKey)"
            let overlay = WeatherMKTileOverlay(urlTemplate: template)
            overlay.weatherType = type
            // Replace map content = no base map underneath, only our tiles
            overlay.canReplaceMapContent = true
            overlay.maximumZ = 15
            overlay.minimumZ = 1
            overlay.tileSize = CGSize(width: 256, height: 256)
            mapView.addOverlay(overlay, level: .aboveLabels)

            Task { @MainActor in
                APILogger.shared.log(
                    service: "OpenWeatherMap",
                    endpoint: "tile/\(type.rawValue)",
                    status: .success,
                    durationMs: 0,
                    detail: "Tile layer activated"
                )
            }
        }

        mapView.isHidden = desired.isEmpty
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = 0.5
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didFailToLoadTilesFor overlay: MKTileOverlay, withError error: Error) {
            Task { @MainActor in
                APILogger.shared.log(
                    service: "OpenWeatherMap",
                    endpoint: "tile load",
                    status: .failure,
                    durationMs: 0,
                    detail: error.localizedDescription
                )
            }
        }
    }
}

class WeatherMKTileOverlay: MKTileOverlay {
    var weatherType: WeatherOverlay = .precipitation
}
