import WeatherKit
import CoreLocation

actor WeatherDataService {
    private let service = WeatherKit.WeatherService.shared

    func currentWeather(
        at coordinate: CLLocationCoordinate2D
    ) async -> CurrentWeather? {
        let location = CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        do {
            return try await service.weather(
                for: location,
                including: .current
            )
        } catch {
            print("WeatherKit error: \(error)")
            return nil
        }
    }
}
