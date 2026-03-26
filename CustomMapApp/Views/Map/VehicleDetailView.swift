import SwiftUI
import MapKit

/// Small dot showing a live vehicle on the map
struct VehicleDot: View {
    let vehicle: GTFSVehiclePosition

    var body: some View {
        ZStack {
            Circle()
                .fill(.blue)
                .frame(width: 10, height: 10)
            Circle()
                .stroke(.white, lineWidth: 1.5)
                .frame(width: 10, height: 10)

            // Route number label
            let displayRoute = vehicle.routeShortName.isEmpty ? vehicle.routeId : vehicle.routeShortName
            if !displayRoute.isEmpty && displayRoute.count <= 4 {
                Text(displayRoute)
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Detail sheet for a tapped live vehicle
struct VehicleDetailView: View {
    let vehicle: GTFSVehiclePosition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 40, height: 5)
                    Spacer()
                }
                .padding(.top, 8)

                // Header
                HStack {
                    Image(systemName: "bus.fill")
                        .font(.title)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        if !vehicle.routeShortName.isEmpty {
                            Text("Route \(vehicle.routeShortName)")
                                .font(.title3.bold())
                        } else if !vehicle.routeId.isEmpty {
                            Text("Route \(vehicle.routeId)")
                                .font(.title3.bold())
                        } else {
                            Text("Live Vehicle")
                                .font(.title3.bold())
                        }
                        if let label = vehicle.label {
                            Text("Vehicle \(label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Details
                VStack(alignment: .leading, spacing: 8) {
                    if !vehicle.tripId.isEmpty {
                        Label("Trip: \(vehicle.tripId)", systemImage: "arrow.triangle.swap")
                            .font(.subheadline)
                    }

                    if let speed = vehicle.speed, speed > 0 {
                        let kmh = Int(speed * 3.6)
                        Label("Speed: \(kmh) km/h", systemImage: "speedometer")
                            .font(.subheadline)
                    }

                    if let bearing = vehicle.bearing {
                        Label("Heading: \(compassDirection(bearing))° (\(compassName(bearing)))", systemImage: "safari")
                            .font(.subheadline)
                    }

                    if let ts = vehicle.timestamp {
                        Label("Updated: \(ts, style: .relative) ago", systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Label(String(format: "%.5f, %.5f", vehicle.latitude, vehicle.longitude), systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Open in Apple Maps
                Button(action: {
                    let placemark = MKPlacemark(coordinate: vehicle.coordinate)
                    let item = MKMapItem(placemark: placemark)
                    item.name = vehicle.routeId.isEmpty ? "Vehicle" : "Route \(vehicle.routeId)"
                    item.openInMaps()
                }) {
                    Label("Open in Apple Maps", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func compassDirection(_ bearing: Float) -> Int {
        Int(bearing) % 360
    }

    private func compassName(_ bearing: Float) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((bearing + 22.5) / 45) % 8
        return directions[index]
    }
}
