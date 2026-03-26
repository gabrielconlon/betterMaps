import Foundation
import CoreLocation
import MapKit

// MARK: - Bicycle Route Preferences

enum BicycleRoutePreference: String, CaseIterable, Identifiable {
    case fastest = "fastest"
    case recommended = "recommended"  // Favors bike lanes, quieter roads
    case shortest = "shortest"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fastest: return "Fastest"
        case .recommended: return "Quieter & Safer"
        case .shortest: return "Shortest"
        }
    }

    var description: String {
        switch self {
        case .fastest: return "Minimize travel time"
        case .recommended: return "Prefers bike lanes and quieter roads"
        case .shortest: return "Minimize distance"
        }
    }

    var systemImage: String {
        switch self {
        case .fastest: return "hare"
        case .recommended: return "leaf"
        case .shortest: return "arrow.forward"
        }
    }
}

// MARK: - ORS Response Models

struct ORSDirectionsResponse: Decodable {
    let features: [ORSFeature]
}

struct ORSFeature: Decodable {
    let properties: ORSProperties
    let geometry: ORSGeometry
}

struct ORSProperties: Decodable {
    let summary: ORSSummary
    let segments: [ORSSegment]?
    let extras: ORSExtras?
}

struct ORSSummary: Decodable {
    let distance: Double  // meters
    let duration: Double  // seconds
}

struct ORSSegment: Decodable {
    let distance: Double
    let duration: Double
    let steps: [ORSStep]?
}

struct ORSStep: Decodable {
    let distance: Double
    let duration: Double
    let instruction: String
    let name: String
}

struct ORSExtras: Decodable {
    let waytypes: ORSExtraValues?
    let surface: ORSExtraValues?

    enum CodingKeys: String, CodingKey {
        case waytypes, surface
    }
}

struct ORSExtraValues: Decodable {
    let values: [[Int]]?
    let summary: [ORSExtraSummary]?
}

struct ORSExtraSummary: Decodable {
    let value: Double
    let distance: Double
    let amount: Double
}

struct ORSGeometry: Decodable {
    let coordinates: [[Double]]  // [lng, lat, elevation?]
}

// MARK: - Bicycle Route Result

struct BicycleRouteResult {
    let polyline: MKPolyline
    let distance: CLLocationDistance      // meters
    let duration: TimeInterval            // seconds
    let preference: BicycleRoutePreference
    let hasBikeLanes: Bool
    let bikeLanePercentage: Double        // 0-100
    let surfaceInfo: String?
    let coordinates: [CLLocationCoordinate2D]
}

// MARK: - Service

actor BicycleRoutingService {
    nonisolated(unsafe) static var apiKey: String = ""

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    func calculateRoute(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        preference: BicycleRoutePreference = .recommended
    ) async -> BicycleRouteResult? {
        guard BicycleRoutingService.isConfigured else { return nil }

        guard let url = URL(string: "https://api.openrouteservice.org/v2/directions/cycling-regular/geojson") else {
            return nil
        }

        // Build request body
        // NOTE: "extra_info" (waytypes, surface) is NOT supported on the ORS free tier.
        // Paid plans support it — would enable bike lane % and surface quality details.
        // The "recommended" preference still routes via bike-friendly roads without it.
        let body: [String: Any] = [
            "coordinates": [
                [source.longitude, source.latitude],
                [destination.longitude, destination.latitude]
            ],
            "preference": preference.rawValue,
            "units": "m",
            "geometry": true,
            "instructions": true
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(BicycleRoutingService.apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Capture rate limit headers
            await APILogger.shared.updateQuota(service: "OpenRouteService", from: response)

            // Check for API error response
            if httpStatus != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                await APILogger.shared.log(service: "OpenRouteService", endpoint: "cycling-regular", status: .failure, durationMs: ms, detail: "HTTP \(httpStatus): \(String(errorBody.prefix(200)))")
                return nil
            }

            let decoded = try JSONDecoder().decode(ORSDirectionsResponse.self, from: data)
            await APILogger.shared.log(service: "OpenRouteService", endpoint: "cycling-regular (\(preference.rawValue))", status: .success, durationMs: ms)

            guard let feature = decoded.features.first else { return nil }

            // Parse coordinates (ORS returns [lng, lat])
            let coordinates = feature.geometry.coordinates.map { coord in
                CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
            }

            let polyline = MKPolyline(
                coordinates: coordinates,
                count: coordinates.count
            )

            // Analyze bike lane coverage from waytypes
            var bikeLanePercent = 0.0
            if let waytypes = feature.properties.extras?.waytypes?.summary {
                // ORS waytype values: 1=cycleway, 4=road with bike lane
                let cycleLaneTypes = waytypes.filter { $0.value == 1 || $0.value == 4 }
                bikeLanePercent = cycleLaneTypes.reduce(0) { $0 + $1.amount }
            }

            // Surface info
            var surfaceInfo: String?
            if let surfaces = feature.properties.extras?.surface?.summary {
                let paved = surfaces.filter { $0.value <= 3 }.reduce(0) { $0 + $1.amount }
                if paved > 80 {
                    surfaceInfo = "Mostly paved"
                } else if paved > 50 {
                    surfaceInfo = "Mixed surface"
                } else {
                    surfaceInfo = "Mostly unpaved"
                }
            }

            return BicycleRouteResult(
                polyline: polyline,
                distance: feature.properties.summary.distance,
                duration: feature.properties.summary.duration,
                preference: preference,
                hasBikeLanes: bikeLanePercent > 30,
                bikeLanePercentage: bikeLanePercent,
                surfaceInfo: surfaceInfo,
                coordinates: coordinates
            )
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.log(service: "OpenRouteService", endpoint: "cycling-regular", status: .failure, durationMs: ms, detail: error.localizedDescription)
            return nil
        }
    }
}
