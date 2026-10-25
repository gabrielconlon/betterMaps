import XCTest
import CloudKit
@testable import CustomMapApp

/// The Settings "iCloud sync" row. The point of it is that a device which
/// cannot sync says so, so these pin the precedence of the reasons.
final class CloudSyncStatusTests: XCTestCase {

    private func status(mode: SyncStoreMode = .iCloud, account: CKAccountStatus? = .available,
                        syncing: Bool = false, success: Date? = nil, error: String? = nil) -> CloudSyncMonitor.Status {
        CloudSyncMonitor.status(mode: mode, account: account, isSyncing: syncing,
                                lastSuccess: success, lastError: error)
    }

    func testFallbackStoresAreProblemsWhateverElseIsTrue() {
        for mode in [SyncStoreMode.localOnly, .inMemory] {
            let s = status(mode: mode, syncing: true, success: Date())
            XCTAssertEqual(s.title, "Off")
            XCTAssertTrue(s.isProblem)
        }
    }

    func testNoAccountBeatsAnOldSuccess() {
        let s = status(account: .noAccount, success: Date())
        XCTAssertEqual(s.title, "Off")
        XCTAssertTrue(s.isProblem)
    }

    func testMirrorErrorBeatsSyncing() {
        let s = status(syncing: true, error: "iCloud storage is full, so new changes can't upload.")
        XCTAssertEqual(s.title, "Problem")
        XCTAssertEqual(s.detail, "iCloud storage is full, so new changes can't upload.")
    }

    func testSyncingThenSynced() {
        XCTAssertEqual(status(syncing: true).title, "Syncing…")
        let done = status(success: Date())
        XCTAssertEqual(done.title, "On")
        XCTAssertFalse(done.isProblem)
        XCTAssertNotNil(done.detail)
    }

    func testUnknownAccountIsNotAProblemYet() {
        let s = status(account: nil)
        XCTAssertEqual(s.title, "On")
        XCTAssertFalse(s.isProblem)
    }

    func testDescribesCommonCloudKitErrors() {
        XCTAssertEqual(CloudSyncMonitor.describe(CKError(.quotaExceeded)),
                       "iCloud storage is full, so new changes can't upload.")
        XCTAssertEqual(CloudSyncMonitor.describe(CKError(.notAuthenticated)), "Not signed in to iCloud.")
    }
}
