import Foundation
import Observation

struct APILogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let service: String
    let endpoint: String
    let status: APILogStatus
    let durationMs: Int
    let detail: String?
}

enum APILogStatus: String {
    case success = "Success"
    case failure = "Failed"
    case cached = "Cached"
}

/// Tracks rate limit info from API response headers
struct APIQuota {
    let limit: Int          // Max calls allowed
    let remaining: Int      // Calls remaining
    let used: Int           // Calls used
    let lastUpdated: Date

    var usagePercent: Double {
        guard limit > 0 else { return 0 }
        return Double(used) / Double(limit) * 100
    }

    var staleness: String {
        let seconds = Int(Date().timeIntervalSince(lastUpdated))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

@Observable
@MainActor
class APILogger {
    static let shared = APILogger()

    var entries: [APILogEntry] = []
    var quotas: [String: APIQuota] = [:]  // keyed by service name

    /// Total bytes downloaded, persisted across sessions
    var totalBytesDownloaded: Int {
        get { UserDefaults.standard.integer(forKey: "totalBytesDownloaded") }
        set { UserDefaults.standard.set(newValue, forKey: "totalBytesDownloaded") }
    }

    /// Formatted data usage string
    var formattedDataUsage: String {
        let bytes = totalBytesDownloaded
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    /// Record bytes from a network response
    func trackBytes(_ count: Int) {
        totalBytesDownloaded += count
    }

    /// Reset data usage counter
    func resetDataUsage() {
        totalBytesDownloaded = 0
    }

    var recentFailures: Int {
        let cutoff = Date().addingTimeInterval(-3600)
        return entries.filter { $0.timestamp > cutoff && $0.status == .failure }.count
    }

    var totalCalls: Int { entries.count }

    var callsByService: [(service: String, count: Int)] {
        let grouped = Dictionary(grouping: entries, by: \.service)
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.count > $1.count }
    }

    /// Most recent successful (or cached) timestamp per service. Used by
    /// the Settings "Data Sources" view to surface "Irish Rail: 12s ago"
    /// per-source freshness alongside the GTFS schedule's mtime — the
    /// architecture has tracked these in `entries` all along but never
    /// surfaced them outside the API Log.
    var lastSuccessByService: [String: Date] {
        var result: [String: Date] = [:]
        for entry in entries where entry.status != .failure {
            if result[entry.service] == nil {
                result[entry.service] = entry.timestamp
            }
        }
        return result
    }

    /// Format a Date as "Xs / Xm / Xh / Xd ago" for compact UI labels.
    static func relativeTimeString(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    func log(service: String, endpoint: String, status: APILogStatus, durationMs: Int, detail: String? = nil) {
        let entry = APILogEntry(
            timestamp: Date(),
            service: service,
            endpoint: endpoint,
            status: status,
            durationMs: durationMs,
            detail: detail
        )
        entries.insert(entry, at: 0)
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }
    }

    /// Update quota from HTTP response headers
    func updateQuota(service: String, from response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else { return }
        let headers = http.allHeaderFields

        // ORS uses: x-ratelimit-limit, x-ratelimit-remaining, x-ratelimit-used
        // Yelp uses: ratelimit-dailylimit, ratelimit-remaining, ratelimit-resettime
        // OpenWeatherMap: doesn't return quota headers (track locally)

        var limit: Int?
        var remaining: Int?

        // Try ORS-style headers
        if let l = headerInt(headers, "x-ratelimit-limit") ?? headerInt(headers, "X-Ratelimit-Limit") {
            limit = l
        }
        if let r = headerInt(headers, "x-ratelimit-remaining") ?? headerInt(headers, "X-Ratelimit-Remaining") {
            remaining = r
        }

        // Try Yelp-style headers
        if limit == nil {
            if let l = headerInt(headers, "ratelimit-dailylimit") ?? headerInt(headers, "RateLimit-DailyLimit") {
                limit = l
            }
        }
        if remaining == nil {
            if let r = headerInt(headers, "ratelimit-remaining") ?? headerInt(headers, "RateLimit-Remaining") {
                remaining = r
            }
        }

        // Generic RFC headers
        if limit == nil {
            limit = headerInt(headers, "RateLimit-Limit") ?? headerInt(headers, "X-Rate-Limit-Limit")
        }
        if remaining == nil {
            remaining = headerInt(headers, "RateLimit-Remaining") ?? headerInt(headers, "X-Rate-Limit-Remaining")
        }

        if let limit, let remaining {
            quotas[service] = APIQuota(
                limit: limit,
                remaining: remaining,
                used: limit - remaining,
                lastUpdated: Date()
            )
        }
    }

    private func headerInt(_ headers: [AnyHashable: Any], _ key: String) -> Int? {
        if let value = headers[key] {
            if let intVal = value as? Int { return intVal }
            if let strVal = value as? String { return Int(strVal) }
        }
        return nil
    }

    func clear() {
        entries = []
    }
}
