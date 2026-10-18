import Foundation
import Observation

/// Main-actor mirror of `BusTimetableService`'s download state for the
/// sheet's status row and Settings. Copy here is human-facing only.
@Observable
@MainActor
final class BusTimetableModel {
    private(set) var state: BusTimetableService.DownloadState?
    private(set) var bytes: Int64?
    private(set) var builtDate: Date?
    /// Set after "Update" until the background check has had a chance to run.
    private(set) var isCheckingForUpdate = false

    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private let service: BusTimetableService

    init(service: BusTimetableService = .shared) {
        self.service = service
    }

    func refresh() async {
        let current = await service.currentState()
        let info = await service.localInfo()
        state = current
        bytes = info?.bytes
        builtDate = (info?.built ?? Self.built(from: current)).flatMap(BusTimetableService.isoDay)
    }

    /// Starts (or attaches to) the download and follows it to the end.
    func download() {
        watcher?.cancel()
        state = .downloading(fraction: 0)
        watcher = Task { [weak self, service] in
            let stream = await service.ensureAvailable()
            for await next in stream {
                guard let self, !Task.isCancelled else { return }
                self.state = next
            }
            await self?.refresh()
        }
    }

    /// Asks the service to fetch a newer build if one exists. The current
    /// timetable keeps working while it checks.
    func checkForUpdate() {
        isCheckingForUpdate = true
        Task { [weak self, service] in
            await service.refreshIfStale(days: 0)
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            await self.refresh()
            self.isCheckingForUpdate = false
        }
    }

    func remove() {
        watcher?.cancel()
        Task { [weak self, service] in
            await service.deleteDownload()
            await self?.refresh()
        }
    }

    // MARK: - Copy

    var statusText: String {
        switch state {
        case nil: return "Checking…"
        case .notDownloaded: return "Download to see bus departure times"
        case .downloading(let fraction): return "Downloading \(Int((fraction * 100).rounded()))%"
        case .ready: return builtDate.map { "Updated \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "On this device"
        case .failed: return BusTimetableService.unavailableMessage
        }
    }

    var sizeText: String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private static func built(from state: BusTimetableService.DownloadState?) -> String? {
        if case .ready(let built) = state { return built }
        return nil
    }
}
