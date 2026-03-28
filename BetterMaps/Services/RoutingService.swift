import MapKit

actor RoutingService {
    func calculateRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [(TransportMode, MKRoute)] {
        await withTaskGroup(of: (TransportMode, MKRoute?).self) { group in
            // Only request MapKit-supported modes (not cycling)
            for mode in TransportMode.mapKitModes {
                group.addTask {
                    guard let transportType = mode.mkTransportType else {
                        return (mode, nil)
                    }
                    let request = MKDirections.Request()
                    request.source = MKMapItem(
                        placemark: MKPlacemark(coordinate: source)
                    )
                    request.destination = MKMapItem(
                        placemark: MKPlacemark(coordinate: destination)
                    )
                    request.transportType = transportType

                    let directions = MKDirections(request: request)
                    do {
                        let response = try await directions.calculate()
                        return (mode, response.routes.first)
                    } catch {
                        return (mode, nil)
                    }
                }
            }

            var results: [(TransportMode, MKRoute)] = []
            for await (mode, route) in group {
                if let route {
                    results.append((mode, route))
                }
            }
            return results
        }
    }
}

extension MKRoute: @unchecked Sendable {}
extension MKPolyline: @unchecked Sendable {}
