import XCTest
@testable import CustomMapApp

@MainActor
final class TransitLayerSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TransitLayerSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFreshDefaultsAreEmpty() {
        let settings = TransitLayerSettings(defaults: defaults)
        XCTAssertTrue(settings.enabledKinds.isEmpty)
        XCTAssertTrue(settings.pinnedStopIds.isEmpty)
    }

    func testEnabledKindsRoundTrip() {
        let settings = TransitLayerSettings(defaults: defaults)
        settings.toggle(.bus)
        settings.toggle(.dart)
        settings.toggle(.luas)
        settings.toggle(.luas)
        XCTAssertTrue(settings.isEnabled(.bus))
        XCTAssertFalse(settings.isEnabled(.luas))
        XCTAssertEqual(defaults.string(forKey: TransitLayerSettings.enabledKindsKey), #"["bus","dart"]"#)

        let reloaded = TransitLayerSettings(defaults: defaults)
        XCTAssertEqual(reloaded.enabledKinds, [.bus, .dart])
        reloaded.disableAll()
        XCTAssertEqual(TransitLayerSettings(defaults: defaults).enabledKinds, [])
    }

    func testReadsJSONStringWrittenExternally() {
        // What `simctl spawn booted defaults write ... -string '[...]'` stores.
        defaults.set(#"["luas","dart","rail","bus"]"#, forKey: TransitLayerSettings.enabledKindsKey)
        XCTAssertEqual(TransitLayerSettings(defaults: defaults).enabledKinds, Set(TransitLayerKind.allCases))
    }

    func testLegacyKeyMigratesAndIsDeleted() {
        defaults.set("bus,luas,suburban", forKey: TransitLayerSettings.legacyEnabledKey)
        let settings = TransitLayerSettings(defaults: defaults)
        XCTAssertEqual(settings.enabledKinds, [.bus, .luas, .rail])
        XCTAssertNil(defaults.object(forKey: TransitLayerSettings.legacyEnabledKey))
        XCTAssertEqual(TransitLayerSettings(defaults: defaults).enabledKinds, [.bus, .luas, .rail])
    }

    func testLegacyEmptyStringMigratesToNothing() {
        defaults.set("", forKey: TransitLayerSettings.legacyEnabledKey)
        let settings = TransitLayerSettings(defaults: defaults)
        XCTAssertTrue(settings.enabledKinds.isEmpty)
        XCTAssertNil(defaults.object(forKey: TransitLayerSettings.legacyEnabledKey))
    }

    func testNewKeyWinsOverLegacy() {
        defaults.set(#"["dart"]"#, forKey: TransitLayerSettings.enabledKindsKey)
        defaults.set("bus,luas", forKey: TransitLayerSettings.legacyEnabledKey)
        XCTAssertEqual(TransitLayerSettings(defaults: defaults).enabledKinds, [.dart])
        XCTAssertNil(defaults.object(forKey: TransitLayerSettings.legacyEnabledKey))
    }

    func testPinnedStopsKeepCommaFormat() {
        defaults.set("8220DB000002,8220GA00408", forKey: TransitLayerSettings.pinnedStopIdsKey)
        let settings = TransitLayerSettings(defaults: defaults)
        XCTAssertEqual(settings.pinnedStopIds, ["8220DB000002", "8220GA00408"])
        settings.togglePinned("8220IR0025")
        settings.togglePinned("8220DB000002")
        XCTAssertTrue(settings.isPinned("8220IR0025"))
        XCTAssertEqual(defaults.string(forKey: TransitLayerSettings.pinnedStopIdsKey), "8220GA00408,8220IR0025")
    }
}
