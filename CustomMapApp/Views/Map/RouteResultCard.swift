import SwiftUI

struct RouteResultCard: View {
    let result: RouteResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.mode.systemImage)
                .font(.title2)
                .foregroundStyle(result.mode.color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.mode.displayName)
                        .font(.headline)
                    if result.isPreferred {
                        Text("Fastest")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 12) {
                    Text(formattedDuration(result.eta))
                        .font(.subheadline.bold())
                    Text(formattedDistance(result.distance))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let warning = result.weatherWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(result.isPreferred
                    ? Color.green.opacity(0.05)
                    : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(result.isPreferred ? Color.green.opacity(0.3) : Color.gray.opacity(0.2))
        )
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(remainingMinutes) min"
    }

    private func formattedDistance(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles < 0.1 {
            let feet = Int(meters * 3.28084)
            return "\(feet) ft"
        }
        return String(format: "%.1f mi", miles)
    }
}
