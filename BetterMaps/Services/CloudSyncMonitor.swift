import Foundation
import CoreData
import CloudKit
import Observation
import os

/// Which store `AppModelContainer.make()` ended up opening. Only `.iCloud`
/// syncs; the other two are its fallbacks and used to be invisible, so a
/// device that had quietly fallen back looked exactly like one that synced.
enum SyncStoreMode: Sendable, Equatable {
    case iCloud, localOnly, inMemory
}

/// What the Settings "iCloud sync" row shows: which store opened, whether the
/// device has an iCloud account, and what the CloudKit mirror last did.
///
/// SwiftData mirrors through `NSPersistentCloudKitContainer`, which still
/// posts `eventChangedNotification` for every setup, import and export, so
/// this reads those rather than inferring sync from data arriving. Observing
/// starts at launch (`start`), not when Settings opens, or the first import
/// would already be over by the time anyone looks.
@MainActor
@Observable
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    static let containerIdentifier = "iCloud.com.gabrielconlon.CustomMapApp"

    private(set) var storeMode: SyncStoreMode = .iCloud
    private(set) var accountStatus: CKAccountStatus?
    private(set) var isSyncing = false
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var inFlight: Set<UUID> = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp",
        category: "sync"
    )

    func start(storeMode: SyncStoreMode) {
        self.storeMode = storeMode
        guard storeMode == .iCloud, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let id = event.identifier
            let kind = Self.kindName(event.type)
            let ended = event.endDate
            let succeeded = event.succeeded
            let message = event.error.map(Self.describe)
            MainActor.assumeIsolated {
                self?.record(id: id, kind: kind, endDate: ended, succeeded: succeeded, error: message)
            }
        }
    }

    /// Re-reads the iCloud account. Cheap; Settings calls it on appear.
    func refreshAccountStatus() async {
        guard storeMode == .iCloud else { return }
        do {
            accountStatus = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
        } catch {
            Self.logger.error("accountStatus failed: \(String(describing: error), privacy: .public)")
            accountStatus = .couldNotDetermine
        }
    }

    private func record(id: UUID, kind: String, endDate: Date?, succeeded: Bool, error: String?) {
        guard let endDate else {
            inFlight.insert(id)
            isSyncing = true
            return
        }
        inFlight.remove(id)
        isSyncing = !inFlight.isEmpty
        if succeeded {
            lastSuccess = endDate
            lastError = nil
        } else {
            lastError = error ?? "Unknown error"
            Self.logger.error("CloudKit \(kind, privacy: .public) failed: \(error ?? "nil", privacy: .public)")
        }
    }

    var status: Status {
        Self.status(mode: storeMode, account: accountStatus, isSyncing: isSyncing,
                    lastSuccess: lastSuccess, lastError: lastError)
    }

    // MARK: - Pure

    struct Status: Equatable, Sendable {
        let title: String
        let detail: String?
        let isProblem: Bool
    }

    /// Precedence: a store that cannot sync, then an account that cannot,
    /// then the mirror's own last error, then progress.
    nonisolated static func status(mode: SyncStoreMode, account: CKAccountStatus?, isSyncing: Bool,
                                   lastSuccess: Date?, lastError: String?) -> Status {
        switch mode {
        case .inMemory:
            return Status(title: "Off", detail: "The app couldn't open its storage, so changes made now won't be kept. Quit and reopen it.", isProblem: true)
        case .localOnly:
            return Status(title: "Off", detail: "iCloud couldn't start, so changes stay on this device. Check you're signed in to iCloud, then quit and reopen the app.", isProblem: true)
        case .iCloud:
            break
        }
        switch account {
        case .noAccount?:
            return Status(title: "Off", detail: "This device isn't signed in to iCloud. Sign in under Settings to sync with your other devices.", isProblem: true)
        case .restricted?:
            return Status(title: "Off", detail: "iCloud is restricted on this device.", isProblem: true)
        case .temporarilyUnavailable?:
            return Status(title: "Paused", detail: "iCloud is temporarily unavailable. Changes are saved and will sync when it's back.", isProblem: true)
        default:
            break
        }
        if let lastError {
            return Status(title: "Problem", detail: lastError, isProblem: true)
        }
        if isSyncing {
            return Status(title: "Syncing…", detail: nil, isProblem: false)
        }
        if let lastSuccess {
            return Status(title: "On", detail: "Last synced \(lastSuccess.formatted(date: .omitted, time: .shortened)).", isProblem: false)
        }
        return Status(title: "On", detail: nil, isProblem: false)
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .notAuthenticated: return "Not signed in to iCloud."
        case .quotaExceeded: return "iCloud storage is full, so new changes can't upload."
        case .networkUnavailable, .networkFailure: return "No connection. Changes will sync when you're back online."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "iCloud is busy. It will retry on its own."
        default: return ck.localizedDescription
        }
    }

    nonisolated private static func kindName(_ type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: return "setup"
        case .import: return "import"
        case .export: return "export"
        @unknown default: return "event"
        }
    }
}
