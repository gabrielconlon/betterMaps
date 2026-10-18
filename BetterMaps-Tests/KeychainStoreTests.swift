import XCTest
@testable import CustomMapApp

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private var defaults: UserDefaults!
    private let suite = "KeychainStoreTests"

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.gabrielconlon.CustomMapAppTests.\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        // The simulator test host can lack Keychain access; skip rather than fail.
        guard store.set("probe", for: "probe") else {
            throw XCTSkip("Keychain unavailable in this test environment")
        }
        store.delete("probe")
    }

    override func tearDown() {
        store.delete(YelpService.keychainAccount)
        store.delete("k")
        defaults.removePersistentDomain(forName: suite)
    }

    func testRoundTripUpdateAndDelete() {
        XCTAssertNil(store.string(for: "k"))
        XCTAssertTrue(store.set("first", for: "k"))
        XCTAssertEqual(store.string(for: "k"), "first")
        XCTAssertTrue(store.set("second", for: "k"), "updates in place")
        XCTAssertEqual(store.string(for: "k"), "second")
        XCTAssertTrue(store.set("", for: "k"), "empty deletes")
        XCTAssertNil(store.string(for: "k"))
        XCTAssertTrue(store.delete("k"), "deleting nothing is fine")
    }

    func testYelpKeyMigratesOutOfUserDefaultsOnce() {
        defaults.set("  legacy-key ", forKey: YelpService.legacyDefaultsKey)
        XCTAssertEqual(YelpService.loadKey(keychain: store, defaults: defaults), "legacy-key")
        XCTAssertNil(defaults.string(forKey: YelpService.legacyDefaultsKey), "plain-text copy is deleted")
        XCTAssertEqual(YelpService.loadKey(keychain: store, defaults: defaults), "legacy-key")
    }

    func testMigrationKeepsAnExistingKeychainKey() {
        store.set("newer", for: YelpService.keychainAccount)
        defaults.set("older", forKey: YelpService.legacyDefaultsKey)
        XCTAssertEqual(YelpService.loadKey(keychain: store, defaults: defaults), "newer")
        XCTAssertNil(defaults.string(forKey: YelpService.legacyDefaultsKey))
    }
}
