import XCTest
@testable import CustomMapApp

@MainActor
final class TagFilterTests: XCTestCase {

    /// A fresh, empty UserDefaults suite that is wiped when the test ends.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "TagFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    let brunch = LayerLite(id: UUID(), name: "Brunch", sortOrder: 0)
    let por = LayerLite(id: UUID(), name: "POR", sortOrder: 1)
    let bars = LayerLite(id: UUID(), name: "Bars", sortOrder: 2)
    let walks = LayerLite(id: UUID(), name: "Walks", isVisible: false, kind: .waypointPath, sortOrder: 3)

    private func tags(visible: Set<UUID>) -> [LayerLite] {
        [brunch, por, bars].map {
            LayerLite(id: $0.id, name: $0.name, isVisible: visible.contains($0.id), sortOrder: $0.sortOrder)
        } + [walks]
    }

    // MARK: - Defaults and persistence

    func testDefaultsToEmptyAny() throws {
        let filter = TagFilter(defaults: try makeDefaults())
        XCTAssertTrue(filter.selectedTagIds.isEmpty)
        XCTAssertEqual(filter.match, .any)
        XCTAssertFalse(filter.hasSelection)
    }

    func testSelectionAndMatchPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let first = TagFilter(defaults: defaults)
        first.toggle(brunch.id)
        first.toggle(por.id)
        first.match = .all
        XCTAssertEqual(defaults.string(forKey: TagFilter.matchKey), "all", "stored value, not display text")
        XCTAssertNotNil(defaults.string(forKey: TagFilter.idsKey))

        let second = TagFilter(defaults: defaults)
        XCTAssertEqual(second.selectedTagIds, [brunch.id, por.id])
        XCTAssertEqual(second.match, .all)

        second.toggle(brunch.id)
        second.clear()
        second.match = .any
        let third = TagFilter(defaults: defaults)
        XCTAssertTrue(third.selectedTagIds.isEmpty)
        XCTAssertEqual(third.match, .any)
    }

    func testGarbageStoredValuesFallBack() throws {
        let defaults = try makeDefaults()
        defaults.set("nonsense", forKey: TagFilter.matchKey)
        defaults.set("not json", forKey: TagFilter.idsKey)
        let filter = TagFilter(defaults: defaults)
        XCTAssertEqual(filter.match, .any)
        XCTAssertTrue(filter.selectedTagIds.isEmpty)
    }

    func testDisplayStringsAreSeparateFromStoredValues() {
        XCTAssertEqual(TagMatch.any.rawValue, "any")
        XCTAssertEqual(TagMatch.all.rawValue, "all")
        XCTAssertEqual(TagMatch.any.title, "Any")
        XCTAssertEqual(TagMatch.all.title, "All")
    }

    // MARK: - Pruning

    func testPruneDropsDeletedTagIds() throws {
        let filter = TagFilter(defaults: try makeDefaults())
        filter.selectedTagIds = [brunch.id, por.id]
        filter.prune(existingTagIds: [brunch.id, bars.id])
        XCTAssertEqual(filter.selectedTagIds, [brunch.id])
    }

    func testPruneWithNoKnownTagsKeepsTheSelection() throws {
        let filter = TagFilter(defaults: try makeDefaults())
        filter.selectedTagIds = [brunch.id]
        filter.prune(existingTagIds: [])
        XCTAssertEqual(filter.selectedTagIds, [brunch.id], "an unloaded store must not wipe the selection")
    }

    // MARK: - Migration

    func testMigrationSeedsSelectionWithVisibleSubset() throws {
        let defaults = try makeDefaults()
        defaults.set("Any Layer", forKey: TagFilter.legacyModeKey)
        let filter = TagFilter(defaults: defaults)
        filter.migrateIfNeeded(tags: tags(visible: [brunch.id, por.id]))

        XCTAssertEqual(filter.selectedTagIds, [brunch.id, por.id])
        XCTAssertEqual(filter.match, .any)
        XCTAssertNil(defaults.object(forKey: TagFilter.legacyModeKey), "old key removed")
        XCTAssertEqual(TagFilter(defaults: defaults).selectedTagIds, [brunch.id, por.id], "persisted")
    }

    func testMigrationFromAllLayersSetsMatchAll() throws {
        let defaults = try makeDefaults()
        defaults.set("All Layers", forKey: TagFilter.legacyModeKey)
        let filter = TagFilter(defaults: defaults)
        filter.migrateIfNeeded(tags: tags(visible: [brunch.id, bars.id]))
        XCTAssertEqual(filter.match, .all)
        XCTAssertEqual(filter.selectedTagIds, [brunch.id, bars.id])
    }

    func testMigrationWithAllOrNoTagsVisibleIsEmptySelection() throws {
        let allVisible = TagFilter(defaults: try makeDefaults())
        allVisible.migrateIfNeeded(tags: tags(visible: [brunch.id, por.id, bars.id]))
        XCTAssertTrue(allVisible.selectedTagIds.isEmpty, "trail groups never count")

        let noneVisible = TagFilter(defaults: try makeDefaults())
        noneVisible.migrateIfNeeded(tags: tags(visible: []))
        XCTAssertTrue(noneVisible.selectedTagIds.isEmpty)
    }

    func testMigrationRunsOnce() throws {
        let defaults = try makeDefaults()
        let filter = TagFilter(defaults: defaults)
        filter.migrateIfNeeded(tags: tags(visible: [brunch.id]))
        XCTAssertEqual(filter.selectedTagIds, [brunch.id])

        filter.clear()
        filter.migrateIfNeeded(tags: tags(visible: [por.id]))
        XCTAssertTrue(filter.selectedTagIds.isEmpty, "a second run changes nothing")
        TagFilter(defaults: defaults).migrateIfNeeded(tags: tags(visible: [por.id]))
        XCTAssertTrue(TagFilter(defaults: defaults).selectedTagIds.isEmpty, "nor on the next launch")
    }

    func testMigrationWaitsUntilTagsExist() throws {
        let defaults = try makeDefaults()
        defaults.set("All Layers", forKey: TagFilter.legacyModeKey)
        let filter = TagFilter(defaults: defaults)
        filter.migrateIfNeeded(tags: [walks])
        XCTAssertNotNil(defaults.object(forKey: TagFilter.legacyModeKey), "no tags yet: not migrated")
        XCTAssertFalse(defaults.bool(forKey: TagFilter.migratedKey))

        filter.migrateIfNeeded(tags: tags(visible: [por.id]))
        XCTAssertEqual(filter.selectedTagIds, [por.id])
        XCTAssertEqual(filter.match, .all)
    }

    // MARK: - End to end with LayerMath

    func testMigratedSelectionShowsTheSamePlacesAsBefore() throws {
        // Before: Brunch and POR visible, Bars hidden, "All Layers".
        let defaults = try makeDefaults()
        defaults.set("All Layers", forKey: TagFilter.legacyModeKey)
        let filter = TagFilter(defaults: defaults)
        let layers = tags(visible: [brunch.id, por.id])
        filter.migrateIfNeeded(tags: layers)

        let both = PlaceLite(id: UUID(), name: "both", layerIds: [brunch.id, por.id])
        let brunchOnly = PlaceLite(id: UUID(), name: "brunch", layerIds: [brunch.id])
        let bar = PlaceLite(id: UUID(), name: "bar", layerIds: [bars.id])
        let out = LayerMath.filter([both, brunchOnly, bar], layers: layers,
                                   filter: PlaceFilter(tagIds: filter.selectedTagIds, match: filter.match))
        XCTAssertEqual(out.map(\.id), [both.id])
    }
}
