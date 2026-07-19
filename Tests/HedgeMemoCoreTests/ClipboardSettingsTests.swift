import XCTest

@testable import HedgeMemoCore

/// Covers `ClipboardHistorySettings` normalization, migration and the
/// category-order/enable bookkeeping, plus `ClipboardCategoryKey` round-tripping.
final class ClipboardSettingsTests: XCTestCase {
    // MARK: - Defaults & migration

    func testDefaultsAndLegacyHotKeyMigration() {
        XCTAssertEqual(HotKeyDefinition.defaultClipboard.displayName, "Command + Shift + V")

        var legacy = ClipboardHistorySettings(hotKey: .legacyClipboard, lastCategory: nil)
        legacy.normalize()
        XCTAssertEqual(legacy.hotKey, .defaultClipboard, "legacy Option+Space migrates forward")
        XCTAssertEqual(legacy.activeCategoryKey, .builtin(.text), "missing last category defaults to text")
    }

    func testDefaultCategoryOrderIncludesEveryBuiltin() {
        var settings = ClipboardHistorySettings()
        settings.normalize()
        XCTAssertEqual(settings.categoryOrder, ["text", "code", "link", "image", "screenshot"])
    }

    func testMaxEntriesSnapsToNearestChoice() {
        XCTAssertEqual(ClipboardHistorySettings(maxEntries: 130).maxEntries, 100)
        XCTAssertEqual(ClipboardHistorySettings(maxEntries: 280).maxEntries, 300)
        XCTAssertEqual(ClipboardHistorySettings(maxEntries: 9_000).maxEntries, 10_000)
        XCTAssertEqual(ClipboardHistorySettings(maxEntries: 999_999).maxEntries, 10_000)
    }

    // MARK: - Active category

    func testActiveCategoryPersistsIntoStorageValue() {
        var settings = ClipboardHistorySettings()
        settings.activeCategoryKey = .builtin(.code)
        XCTAssertEqual(settings.lastCategory, "code")
        XCTAssertEqual(settings.activeCategoryKey, .builtin(.code))
    }

    // MARK: - Enable / disable

    func testDisablingACategoryExcludesItFromEnabledKeys() {
        var settings = ClipboardHistorySettings()
        settings.normalize()
        XCTAssertTrue(settings.isCategoryEnabled(.builtin(.image)))

        settings.setCategory(.builtin(.image), enabled: false)
        XCTAssertFalse(settings.isCategoryEnabled(.builtin(.image)))
        XCTAssertFalse(settings.enabledCategoryKeys.contains(.builtin(.image)))

        settings.setCategory(.builtin(.image), enabled: true)
        XCTAssertTrue(settings.isCategoryEnabled(.builtin(.image)))
    }

    // MARK: - Custom categories

    func testCustomCategoriesJoinTheOrderAndCanBeLookedUp() {
        let github = CustomClipboardCategory(name: "GitHub", pattern: "github\\.com")
        var settings = ClipboardHistorySettings(customCategories: [github])
        settings.normalize()
        XCTAssertEqual(settings.orderedCategoryKeys.last, .custom(github.id))
        XCTAssertEqual(settings.customCategory(id: github.id)?.name, "GitHub")
    }

    func testRemovingActiveCustomCategoryFallsBackToText() {
        let github = CustomClipboardCategory(name: "GitHub", pattern: "github\\.com")
        var settings = ClipboardHistorySettings(customCategories: [github])
        settings.normalize()
        settings.activeCategoryKey = .custom(github.id)
        settings.customCategories = []
        settings.normalize()
        XCTAssertEqual(settings.activeCategoryKey, .builtin(.text))
        XCTAssertFalse(settings.orderedCategoryKeys.contains(.custom(github.id)))
    }

    func testRegexPatternValidation() {
        XCTAssertTrue(CustomClipboardCategory(name: "ok", pattern: "github\\.com").isPatternValid)
        XCTAssertFalse(CustomClipboardCategory(name: "bad", pattern: "([").isPatternValid)
        XCTAssertFalse(CustomClipboardCategory(name: "empty", pattern: "").isPatternValid)
    }

    // MARK: - ClipboardCategoryKey round-trip

    func testCategoryKeyStorageRoundTrip() {
        XCTAssertEqual(ClipboardCategoryKey.builtin(.text).storageValue, "text")
        XCTAssertEqual(ClipboardCategoryKey(storageValue: "code"), .builtin(.code))

        let id = UUID()
        let stored = ClipboardCategoryKey.custom(id).storageValue
        XCTAssertEqual(stored, "custom:\(id.uuidString)")
        XCTAssertEqual(ClipboardCategoryKey(storageValue: stored), .custom(id))
    }

    func testCategoryKeyRejectsMalformedStorageValues() {
        XCTAssertNil(ClipboardCategoryKey(storageValue: "bogus"))
        XCTAssertNil(ClipboardCategoryKey(storageValue: "custom:not-a-uuid"))
    }
}
