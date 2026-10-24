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
    /// True while an "Update" check (and any download it starts) runs.
    private(set) var isCheckingForUpdate = false
    /// Outcome of the last "Update" check, for the caller to show inline
    /// (see `updateResultText`). Cleared when a new check starts.
    private(set) var updateResult: BusTimetableService.UpdateResult?

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
    /// timetable keeps working while it checks; `updateResult` holds the
    /// answer once the check (and any download) has really finished.
    func checkForUpdate() {
        Task { await checkForUpdateNow() }
    }

    /// Awaitable form of `checkForUpdate()`.
    @discardableResult
    func checkForUpdateNow() async -> BusTimetableService.UpdateResult {
        isCheckingForUpdate = true
        updateResult = nil
        let result = await service.checkForUpdate()
        await refresh()
        updateResult = result
        isCheckingForUpdate = false
        return result
    }

    func remove() {
        watcher?.cancel()
        updateResult = nil
        Task { [weak self, service] in
            await service.deleteDownload()
            await self?.refresh()
        }
    }

    // MARK: - Copy

    var statusText: String {
        switch state {
        case nil: return "Checking…"
        case .notDownloaded: return "Download to see scheduled departure times"
        case .downloading(let fraction): return "Downloading \(Int((fraction * 100).rounded()))%"
        case .ready: return builtDate.map { "Updated \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "On this device"
        case .failed: return BusTimetableService.unavailableMessage
        }
    }

    /// Inline line for the last "Update" check; nil before the first one
    /// and while a check is running.
    var updateResultText: String? {
        guard !isCheckingForUpdate, let updateResult else { return nil }
        return Self.text(for: updateResult)
    }

    nonisolated static func text(for result: BusTimetableService.UpdateResult) -> String {
        switch result {
        case .upToDate: return "Up to date"
        case .updated: return "Updated"
        case .failed: return "Couldn't check for a newer timetable"
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
