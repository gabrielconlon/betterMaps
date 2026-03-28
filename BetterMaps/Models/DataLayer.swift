import Foundation

/// Weather tile overlay types from OpenWeatherMap
enum WeatherOverlay: String, CaseIterable, Identifiable {
    case precipitation = "precipitation_new"
    case clouds = "clouds_new"
    case wind = "wind_new"
    case temperature = "temp_new"
    case pressure = "pressure_new"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .precipitation: return "Precipitation"
        case .clouds: return "Clouds"
        case .wind: return "Wind"
        case .temperature: return "Temperature"
        case .pressure: return "Pressure"
        }
    }

    var systemImage: String {
        switch self {
        case .precipitation: return "cloud.rain.fill"
        case .clouds: return "cloud.fill"
        case .wind: return "wind"
        case .temperature: return "thermometer.medium"
        case .pressure: return "gauge.with.dots.needle.33percent"
        }
    }

    func tileURL(z: Int, x: Int, y: Int, apiKey: String) -> URL? {
        URL(string: "https://tile.openweathermap.org/map/\(rawValue)/\(z)/\(x)/\(y).png?appid=\(apiKey)")
    }
}
