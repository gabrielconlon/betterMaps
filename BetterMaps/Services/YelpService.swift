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
    // Store your Yelp API key here. Get one free at https://www.yelp.com/developers
    // For production, use Keychain or environment variable instead.
    private static let apiKeyStorage = OSAllocatedUnfairLock(initialState: "")
    static var apiKey: String {
        get { apiKeyStorage.withLock { $0 } }
        set { apiKeyStorage.withLock { $0 = newValue } }
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    func searchBusiness(name: String, coordinate: CLLocationCoordinate2D) async -> YelpBusiness? {
        guard YelpService.isConfigured else { return nil }

        var components = URLComponents(string: "https://api.yelp.com/v3/businesses/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "radius", value: "200"),
        ]

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(YelpService.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(YelpSearchResponse.self, from: data)
            guard let business = decoded.businesses.first else { return nil }
            return await fetchBusinessDetails(id: business.id)
        } catch {
            print("[Yelp] businesses/search failed: \(error.localizedDescription)")
            return nil
        }
    }

    func fetchBusinessDetails(id: String) async -> YelpBusiness? {
        guard YelpService.isConfigured else { return nil }
        guard let url = URL(string: "https://api.yelp.com/v3/businesses/\(id)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(YelpService.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(YelpBusiness.self, from: data)
        } catch {
            print("Yelp detail error: \(error)")
            return nil
        }
    }

    func fetchReviews(businessId: String) async -> [YelpReview] {
        guard YelpService.isConfigured else { return [] }
        guard let url = URL(string: "https://api.yelp.com/v3/businesses/\(businessId)/reviews?limit=3&sort_by=yelp_sort") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(YelpService.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(YelpReviewsResponse.self, from: data)
            return response.reviews
        } catch {
            print("Yelp reviews error: \(error)")
            return []
        }
    }
}
