import SwiftUI

struct RouteResultCard: View {
    let result: RouteResult
    var onSelect: (() -> Void)?

    var hasSteps: Bool {
        result.route?.steps.isEmpty == false
    }

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
                    if result.isCached {
                        Text("Saved")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
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

                if result.mode == .cycling {
                    if let bikeInfo = result.bikeLaneInfo {
                        Label(bikeInfo, systemImage: "bicycle")
                            .font(.caption)
                            .foregroundStyle(.teal)
                    }
                }

                if let warning = result.weatherWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button(action: { onSelect?() }) {
                Text(hasSteps ? "Go" : "View")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(result.mode.color)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
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
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours) hr" : "\(hours)h \(rem)m"
    }

    private func formattedDistance(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles < 0.1 { return "\(Int(meters * 3.28084)) ft" }
        return String(format: "%.1f mi", miles)
    }
}
