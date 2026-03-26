import Foundation
import CoreLocation

/// Fetches real-time vehicle positions from NTA GTFS-RT feed
actor LiveVehicleService {
    private let vehicleURL = "https://api.nationaltransport.ie/gtfsr/v2/Vehicles"

    /// Fetch current vehicle positions
    func fetchVehiclePositions() async -> [GTFSVehiclePosition] {
        guard NTATransitService.isConfigured else { return [] }
        guard let url = URL(string: vehicleURL) else { return [] }

        var request = URLRequest(url: url)
        request.setValue(NTATransitService.apiKey, forHTTPHeaderField: "x-api-key")
        // GTFS-RT returns protobuf by default
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.updateQuota(service: "NTA", from: response)

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if httpStatus != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                await APILogger.shared.log(service: "NTA", endpoint: "Vehicles", status: .failure, durationMs: ms, detail: "HTTP \(httpStatus): \(String(body.prefix(200)))")
                return []
            }

            let vehicles = GTFSRealtimeDecoder.decodeVehiclePositions(data: data)
            await APILogger.shared.log(service: "NTA", endpoint: "Vehicles (\(vehicles.count) vehicles)", status: .success, durationMs: ms)
            return vehicles
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await APILogger.shared.log(service: "NTA", endpoint: "Vehicles", status: .failure, durationMs: ms, detail: error.localizedDescription)
            return []
        }
    }
}
