import MapKit

actor RoutingService {
    func calculateRoutes(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [(TransportMode, MKRoute)] {
        await withTaskGroup(of: (TransportMode, MKRoute?).self) { group in
            for mode in TransportMode.allCases {
                group.addTask {
                    let request = MKDirections.Request()
                    request.source = MKMapItem(
                        placemark: MKPlacemark(coordinate: source)
                    )
                    request.destination = MKMapItem(
                        placemark: MKPlacemark(coordinate: destination)
                    )
                    request.transportType = mode.mkTransportType

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

// MKRoute is safe to pass across concurrency boundaries — it's
// a read-only value object returned by MapKit after calculation.
extension MKRoute: @unchecked Sendable {}
