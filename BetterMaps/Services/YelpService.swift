import Foundation
import os
import CoreLocation

// MARK: - Yelp API Models

struct YelpBusiness: Decodable {
    let id: String
    let name: String
    let imageUrl: String?
    let isClosed: Bool?
    let url: String?
    let reviewCount: Int?
    let rating: Double?
    let phone: String?
    let displayPhone: String?
    let hours: [YelpHours]?
    let photos: [String]?
    let price: String?
    let categories: [YelpCategory]?
    let location: YelpLocation?

    enum CodingKeys: String, CodingKey {
        case id, name, url, phone, hours, photos, price, categories, location, rating
        case imageUrl = "image_url"
        case isClosed = "is_closed"
        case reviewCount = "review_count"
        case displayPhone = "display_phone"
    }

    var isCurrentlyOpen: Bool? {
        hours?.first?.isOpenNow
    }

    var todayHours: String? {
        guard let hours = hours?.first?.open else { return nil }
        let calendar = Calendar.current
        // Yelp uses 0 = Monday, ... 6 = Sunday
        let weekday = (calendar.component(.weekday, from: Date()) + 5) % 7
        let todaySlots = hours.filter { $0.day == weekday }
        if todaySlots.isEmpty { return "Closed today" }
        return todaySlots.map { formatTimeRange($0.start, $0.end) }.joined(separator: ", ")
    }

    private func formatTimeRange(_ start: String, _ end: String) -> String {
        "\(formatTime(start)) - \(formatTime(end))"
    }

    private func formatTime(_ time: String) -> String {
        guard time.count == 4,
              let hour = Int(time.prefix(2)),
              let minute = Int(time.suffix(2)) else { return time }
        let h = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour)
        let ampm = hour >= 12 ? "PM" : "AM"
        return minute == 0 ? "\(h) \(ampm)" : "\(h):\(String(format: "%02d", minute)) \(ampm)"
    }
}

struct YelpHours: Decodable {
    let isOpenNow: Bool?
    let open: [YelpHourSlot]?

    enum CodingKeys: String, CodingKey {
        case isOpenNow = "is_open_now"
        case open
    }
}

struct YelpHourSlot: Decodable {
    let day: Int
    let start: String
    let end: String
}

struct YelpCategory: Decodable {
    let alias: String
    let title: String
}

struct YelpLocation: Decodable {
    let displayAddress: [String]?

    enum CodingKeys: String, CodingKey {
        case displayAddress = "display_address"
    }
}

struct YelpSearchResponse: Decodable {
    let businesses: [YelpBusiness]
}

struct YelpReview: Decodable {
    let id: String
    let rating: Int
    let text: String
    let user: YelpUser
    let timeCreated: String

    enum CodingKeys: String, CodingKey {
        case id, rating, text, user
        case timeCreated = "time_created"
    }
}

struct YelpUser: Decodable {
    let name: String
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case imageUrl = "image_url"
    }
}

struct YelpReviewsResponse: Decodable {
    let reviews: [YelpReview]
}

// MARK: - Yelp Service

actor YelpService {
    /// Keychain account holding the optional Yelp Fusion key.
    static let keychainAccount = "yelpAPIKey"
    /// Where older builds kept the key in plain UserDefaults.
    static let legacyDefaultsKey = "yelpAPIKey"

    /// In-memory copy of the Keychain value; nil until first read.
    private static let apiKeyStorage = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The user's Yelp key, kept in the Keychain. The first read moves a key
    /// left in UserDefaults by older builds into the Keychain and deletes it.
    static var apiKey: String {
        get {
            apiKeyStorage.withLock { cached in
                if let cached { return cached }
                let loaded = loadKey()
                cached = loaded
                return loaded
            }
        }
        set {
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKeyStorage.withLock { $0 = key }
            if KeychainStore().set(key, for: keychainAccount) {
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            }
        }
    }

    /// Reads the key, migrating a legacy UserDefaults copy first.
    static func loadKey(keychain: KeychainStore = KeychainStore(),
                        defaults: UserDefaults = .standard) -> String {
        migrateLegacyKey(keychain: keychain, defaults: defaults)
        return keychain.string(for: keychainAccount) ?? ""
    }

    /// One-time move of the key from UserDefaults to the Keychain. The
    /// plain-text copy is deleted only once the Keychain holds a key.
    static func migrateLegacyKey(keychain: KeychainStore = KeychainStore(),
                                 defaults: UserDefaults = .standard) {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || keychain.string(for: keychainAccount) != nil
            || keychain.set(trimmed, for: keychainAccount) {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "yelp"
    )

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    /// Outcome of looking a place up, so callers can tell "Yelp has no match"
    /// (show nothing) from "the request failed" (offer a retry).
    enum Lookup: Sendable {
        case found(YelpBusiness, reviews: [YelpReview])
        case noMatch
        case failed
    }

    /// Business details plus top reviews for the place nearest `coordinate`.
    func lookup(name: String, coordinate: CLLocationCoordinate2D) async -> Lookup {
        guard YelpService.isConfigured else { return .noMatch }
        var components = URLComponents(string: "https://api.yelp.com/v3/businesses/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "radius", value: "200"),
        ]
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(YelpService.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let decoded = try JSONDecoder().decode(YelpSearchResponse.self, from: data)
            guard let match = decoded.businesses.first else { return .noMatch }
            guard let business = await fetchBusinessDetails(id: match.id) else { return .failed }
            return .found(business, reviews: await fetchReviews(businessId: business.id))
        } catch {
            Self.logger.error("search failed: \(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }

    private func fetchBusinessDetails(id: String) async -> YelpBusiness? {
        guard YelpService.isConfigured else { return nil }
        guard let url = URL(string: "https://api.yelp.com/v3/businesses/\(id)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(YelpService.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Self.logger.error("business details HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            return try JSONDecoder().decode(YelpBusiness.self, from: data)
        } catch {
            Self.logger.error("business details failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    private func fetchReviews(businessId: String) async -> [YelpReview] {
        guard YelpService.isConfigured else { return [] }
        guard let url = URL(string: "https://api.yelp.com/v3/businesses/\(businessId)/reviews?limit=3&sort_by=yelp_sort") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(YelpService.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Self.logger.error("reviews HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return []
            }
            return try JSONDecoder().decode(YelpReviewsResponse.self, from: data).reviews
        } catch {
            Self.logger.error("reviews failed: \(String(describing: type(of: error)), privacy: .public)")
            return []
        }
    }
}
