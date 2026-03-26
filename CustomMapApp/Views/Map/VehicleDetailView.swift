import SwiftUI
import MapKit

/// Small dot showing a live vehicle on the map, colored by transit type
struct VehicleDot: View {
    let vehicle: GTFSVehiclePosition

    /// NTA vehicles are buses (blue); extend here if NTA feed gains Luas/rail.
    private var dotColor: Color { .blue }

    var body: some View {
        ZStack {
            Circle()
                .fill(dotColor)
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

/// Small dot showing a live Irish Rail train on the map
struct TrainDot: View {
    let train: IrishRailTrainPosition
    var zoomDelta: Double = 0.01

    /// DART trains are orange; all other trains are purple
    private var dotColor: Color {
        train.trainType.uppercased() == "DART" ? .orange : .purple
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            Circle()
                .stroke(.white, lineWidth: 1.5)
                .frame(width: 10, height: 10)

            // Show trainCode label when zoomed in enough
            if zoomDelta < 0.05 && !train.trainCode.isEmpty && train.trainCode.count <= 6 {
                Text(train.trainCode)
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
                        let primary = vehicle.routeShortName.isEmpty ? vehicle.routeId : vehicle.routeShortName
                        if !primary.isEmpty {
                            Text(primary)
                                .font(.title2.bold())
                            // Show routeId as subtitle when routeShortName is the primary display
                            if !vehicle.routeShortName.isEmpty && !vehicle.routeId.isEmpty && vehicle.routeShortName != vehicle.routeId {
                                Text("Route \(vehicle.routeId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Live Vehicle")
                                .font(.title2.bold())
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

/// Detail sheet for a tapped live Irish Rail train
struct TrainDetailView: View {
    let train: IrishRailTrainPosition

    private var isDart: Bool {
        train.trainType.uppercased() == "DART"
    }

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
                    Image(systemName: "tram.fill")
                        .font(.title)
                        .foregroundStyle(isDart ? .orange : .purple)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(train.trainCode)
                            .font(.title2.bold())
                        Text(isDart ? "DART" : train.trainType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Details
                VStack(alignment: .leading, spacing: 8) {
                    if !train.status.isEmpty {
                        Label("Status: \(train.status)", systemImage: "info.circle")
                            .font(.subheadline)
                    }

                    if !train.direction.isEmpty {
                        Label("Direction: \(train.direction)", systemImage: "arrow.triangle.swap")
                            .font(.subheadline)
                    }

                    if !train.publicMessage.isEmpty {
                        Text(train.publicMessage.replacingOccurrences(of: "\\n", with: "\n"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Label(String(format: "%.5f, %.5f", train.latitude, train.longitude), systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Open in Apple Maps
                Button(action: {
                    let placemark = MKPlacemark(coordinate: train.coordinate)
                    let item = MKMapItem(placemark: placemark)
                    item.name = "\(train.trainType) \(train.trainCode)"
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
}
