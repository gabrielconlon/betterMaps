import SwiftUI

struct APILogView: View {
    let logger = APILogger.shared

    var body: some View {
        List {
            // Quotas
            if !logger.quotas.isEmpty {
                Section("API Usage") {
                    ForEach(Array(logger.quotas.keys.sorted()), id: \.self) { service in
                        if let quota = logger.quotas[service] {
                            APIQuotaRow(service: service, quota: quota)
                        }
                    }
                }
            }

            // Summary
            Section("Session Summary") {
                HStack {
                    Text("Total API Calls")
                    Spacer()
                    Text("\(logger.totalCalls)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Failures (last hour)")
                    Spacer()
                    Text("\(logger.recentFailures)")
                        .foregroundColor(logger.recentFailures > 0 ? .red : .green)
                }

                ForEach(logger.callsByService, id: \.service) { item in
                    HStack {
                        Text(item.service)
                        Spacer()
                        Text("\(item.count) calls")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Log entries
            Section("Recent Calls") {
                if logger.entries.isEmpty {
                    Text("No API calls yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logger.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(statusColor(entry.status))
                                    .frame(width: 8, height: 8)
                                Text(entry.service)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text("\(entry.durationMs)ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.endpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("API Logs")
        .toolbar {
            if !logger.entries.isEmpty {
                Button("Clear") { logger.clear() }
            }
        }
    }

    private func statusColor(_ status: APILogStatus) -> Color {
        switch status {
        case .success: return .green
        case .failure: return .red
        case .cached: return .blue
        }
    }
}

struct APIQuotaRow: View {
    let service: String
    let quota: APIQuota

    var barColor: Color {
        if quota.usagePercent > 90 { return .red }
        if quota.usagePercent > 70 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(service)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(quota.used) / \(quota.limit) calls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Usage bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * min(1, quota.usagePercent / 100)), height: 8)
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(quota.remaining) remaining")
                    .font(.caption2)
                    .foregroundStyle(quota.remaining < 50 ? .orange : .secondary)
                Spacer()
                Text("Updated \(quota.staleness)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
