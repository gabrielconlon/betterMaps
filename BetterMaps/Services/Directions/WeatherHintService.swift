import Foundation
import CoreLocation
import os

/// "Rain likely around 17:00 near Blanchardstown": the wettest hour the
/// forecast sees across both ends of a journey, when it is wet enough to
/// mention.
struct RainHint: Hashable, Sendable {
    let probabilityPercent: Int
    /// Start of the forecast hour.
    let hour: Date
    /// The endpoint the hour belongs to, as the user named it.
    let nearName: String
}

/// Asks Open-Meteo (CC BY 4.0) for the next twelve hours of rain
/// probability at both ends of a journey and boils that down to one
/// `RainHint`, or nothing. Never throws to the caller: a weather hiccup must
/// not get in the way of directions.
///
/// Forecasts change slowly, so each point is cached for 30 minutes (keyed by
/// the coordinate to two decimals, about a kilometre) and the last good
/// answer is served when a refresh fails.
actor WeatherHintService {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    static let forecastHours = 12
    static let cacheLifetime: TimeInterval = 30 * 60
    static let requestTimeout: TimeInterval = 10
    /// The window is widened by this much at both ends so a shower starting
    /// in the hour before departure still counts.
    static let windowPadding: TimeInterval = 3600

    /// One forecast hour; `probability` is nil where the model gave none.
    struct ForecastHour: Hashable, Sendable {
        let time: Date
        let probability: Int?
    }

    private struct CacheKey: Hashable {
        let lat: Int
        let lon: Int

        init(_ coordinate: CLLocationCoordinate2D) {
            lat = Int((coordinate.latitude * 100).rounded())
            lon = Int((coordinate.longitude * 100).rounded())
        }

        var latitude: Double { Double(lat) / 100 }
        var longitude: Double { Double(lon) / 100 }
    }

    private struct Entry {
        let hours: [ForecastHour]
        let fetchedAt: Date
    }

    private let loader: Loader
    private let now: @Sendable () -> Date
    private let userAgent: String
    private var cache: [CacheKey: Entry] = [:]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "directions"
    )

    init(loader: Loader? = nil, now: @escaping @Sendable () -> Date = { Date() }, bundle: Bundle = .main) {
        self.loader = loader ?? { request in try await URLSession.shared.data(for: request) }
        self.now = now
        self.userAgent = MotisQuery.userAgent(bundle: bundle)
    }

    // MARK: - Hint

    /// The wettest hour across both points whose start falls within
    /// `window` widened by an hour each way, when its probability reaches
    /// `threshold`. Nil otherwise, and nil when neither forecast could be
    /// had. Ties go to the origin.
    func hint(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D,
              originName: String, destinationName: String,
              window: ClosedRange<Date>, threshold: Int) async -> RainHint? {
        let originKey = CacheKey(origin)
        let destinationKey = CacheKey(destination)

        let originHours = await forecast(for: originKey)
        let destinationHours = originKey == destinationKey
            ? originHours
            : await forecast(for: destinationKey)

        var best: RainHint?
        for (hours, name) in [(originHours, originName), (destinationHours, destinationName)] {
            guard let hours, let peak = Self.peak(in: hours, window: window) else { continue }
            if peak.probability > (best?.probabilityPercent ?? Int.min) {
                best = RainHint(probabilityPercent: peak.probability, hour: peak.time, nearName: name)
            }
        }
        guard let best, best.probabilityPercent >= threshold else { return nil }
        return best
    }

    /// The hour with the highest probability whose start lies within
    /// `window` padded by `windowPadding` at both ends. Earlier hour wins a
    /// tie so the hint names the first wet spell.
    static func peak(in hours: [ForecastHour], window: ClosedRange<Date>) -> (time: Date, probability: Int)? {
        let lower = window.lowerBound.addingTimeInterval(-windowPadding)
        let upper = window.upperBound.addingTimeInterval(windowPadding)
        var best: (time: Date, probability: Int)?
        for hour in hours where hour.time >= lower && hour.time <= upper {
            guard let probability = hour.probability else { continue }
            if best == nil || probability > best!.probability {
                best = (hour.time, probability)
            }
        }
        return best
    }

    // MARK: - Fetching and cache

    /// Cached forecast for a point; refreshes after `cacheLifetime`, serves
    /// the stale copy when the refresh fails, nil when there is nothing.
    private func forecast(for key: CacheKey) async -> [ForecastHour]? {
        let current = now()
        if let entry = cache[key], current.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime {
            return entry.hours
        }
        do {
            let hours = try await fetch(key)
            cache[key] = Entry(hours: hours, fetchedAt: now())
            return hours
        } catch {
            if let stale = cache[key] {
                Self.logger.info("weather refresh failed, serving stale forecast")
                return stale.hours
            }
            return nil
        }
    }

    private func fetch(_ key: CacheKey) async throws -> [ForecastHour] {
        let url = Self.url(latitude: key.latitude, longitude: key.longitude)
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(request)
        } catch {
            Self.logger.error("weather request failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logger.error("weather HTTP \(http.statusCode)")
            throw URLError(.badServerResponse)
        }
        do {
            return try Self.parse(data)
        } catch {
            Self.logger.error("weather decode failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    /// The forecast URL for a point, coordinates to four decimals.
    static func url(latitude: Double, longitude: Double, base: URL = baseURL) -> URL {
        let posix = Locale(identifier: "en_US_POSIX")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", locale: posix, latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", locale: posix, longitude)),
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation,weather_code"),
            URLQueryItem(name: "forecast_hours", value: String(forecastHours)),
            URLQueryItem(name: "timezone", value: "UTC"),
        ]
        return components.url!
    }

    // MARK: - Parsing

    private struct Response: Decodable {
        let hourly: Hourly

        struct Hourly: Decodable {
            let time: [String]
            let precipitationProbability: [Int?]?

            enum CodingKeys: String, CodingKey {
                case time
                case precipitationProbability = "precipitation_probability"
            }
        }
    }

    /// Open-Meteo writes hours as "2026-11-03T17:00" in the requested zone,
    /// UTC here.
    static func parse(_ data: Data) throws -> [ForecastHour] {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let probabilities = decoded.hourly.precipitationProbability ?? []
        var hours: [ForecastHour] = []
        for (index, raw) in decoded.hourly.time.enumerated() {
            guard let time = formatter.date(from: raw) else { continue }
            let probability = index < probabilities.count ? probabilities[index] : nil
            hours.append(ForecastHour(time: time, probability: probability))
        }
        return hours
    }
}
