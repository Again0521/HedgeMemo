import XCTest

@testable import HedgeMemoCore

/// Covers ordering, quick-slot mapping, merging, trimming and category
/// filtering — the pure rules behind the clipboard list.
final class ClipboardHistoryPolicyTests: XCTestCase {
    private lazy var pinnedFirst = Fixture.text("置顶一", hash: "p1", at: 0, pinned: true, pinnedOrder: 0)
    private lazy var pinnedLater = Fixture.text("置顶二", hash: "p2", at: 20, pinned: true, pinnedOrder: 1)
    private lazy var regularOlder = Fixture.text("普通旧", hash: "r1", at: 10)
    private lazy var regularNewer = Fixture.text("普通新", hash: "r2", at: 30)

    private var mixedOrder: [ClipboardEntry] {
        [regularOlder, pinnedLater, regularNewer, pinnedFirst]
    }

    func testPinnedSortBeforeRegularThenNewestFirst() {
        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(mixedOrder).map(\.id),
            [pinnedFirst.id, pinnedLater.id, regularNewer.id, regularOlder.id]
        )
    }

    func testPinnedEntriesFollowPinnedOrder() {
        XCTAssertEqual(
            ClipboardHistoryPolicy.pinnedEntries(mixedOrder).map(\.id),
            [pinnedFirst.id, pinnedLater.id]
        )
    }

    func testQuickEntryMapsOneBasedOntoPinnedOrder() {
        let ordered = ClipboardHistoryPolicy.ordered(mixedOrder)
        XCTAssertEqual(ClipboardHistoryPolicy.quickEntry(in: ordered, number: 1)?.id, pinnedFirst.id)
        XCTAssertEqual(ClipboardHistoryPolicy.quickEntry(in: ordered, number: 2)?.id, pinnedLater.id)
    }

    func testQuickEntryIgnoresEmptyAndOutOfRangeSlots() {
        let ordered = ClipboardHistoryPolicy.ordered(mixedOrder)
        XCTAssertNil(ClipboardHistoryPolicy.quickEntry(in: ordered, number: 3), "only two pinned exist")
        XCTAssertNil(ClipboardHistoryPolicy.quickEntry(in: ordered, number: 0))
        XCTAssertNil(ClipboardHistoryPolicy.quickEntry(in: ordered, number: 10))
    }

    func testConsecutiveDuplicatesMerge() {
        XCTAssertTrue(ClipboardHistoryPolicy.shouldMergeWithLatest(latest: regularNewer, contentHash: "r2"))
        XCTAssertFalse(ClipboardHistoryPolicy.shouldMergeWithLatest(latest: regularNewer, contentHash: "other"))
        XCTAssertFalse(ClipboardHistoryPolicy.shouldMergeWithLatest(latest: nil, contentHash: "r2"))
    }

    func testTrimKeepsAPracticalMinimum() {
        // Even a tiny configured maximum never trims below ten entries.
        let few = (0..<5).map { Fixture.text("t\($0)", hash: "t\($0)", at: TimeInterval($0)) }
        XCTAssertTrue(ClipboardHistoryPolicy.idsToTrim(from: few, maxEntries: 3).isEmpty)
    }

    func testTrimReturnsTheOldestOverflow() {
        // 12 entries, newest first; a max of 10 drops the two oldest.
        let entries = (0..<12).map { Fixture.text("t\($0)", hash: "t\($0)", at: TimeInterval($0)) }
        let trimmed = Set(ClipboardHistoryPolicy.idsToTrim(from: entries, maxEntries: 10))
        XCTAssertEqual(trimmed, [entries[0].id, entries[1].id])
    }

    // MARK: - Category filtering

    func testBuiltinCategoryFiltersIsolateEachKind() {
        let code = Fixture.text("func f() {\n  return 1;\n}", hash: "code")
        let prose = Fixture.text("周五下班一起吃饭", hash: "prose")
        let image = Fixture.image(hash: "img")
        let link = Fixture.text("https://github.com/Again0521/hedgememo", hash: "url")
        let all = [code, prose, image, link]

        XCTAssertEqual(ClipboardHistoryPolicy.ordered(all, key: .builtin(.code)).map(\.id), [code.id])
        XCTAssertEqual(ClipboardHistoryPolicy.ordered(all, key: .builtin(.text)).map(\.id), [prose.id])
        XCTAssertEqual(ClipboardHistoryPolicy.ordered(all, key: .builtin(.image)).map(\.id), [image.id])
        XCTAssertEqual(ClipboardHistoryPolicy.ordered(all, key: .builtin(.link)).map(\.id), [link.id])
        XCTAssertEqual(Set(ClipboardHistoryPolicy.ordered(all, key: nil).map(\.id)), Set(all.map(\.id)))
    }

    func testCustomRegexCategoryFiltersMatchingText() {
        let link = Fixture.text("https://github.com/x", hash: "url")
        let prose = Fixture.text("周五下班", hash: "prose")
        let github = CustomClipboardCategory(name: "GitHub", pattern: "github\\.com")
        let filtered = ClipboardHistoryPolicy.ordered(
            [link, prose], key: .custom(github.id), customCategories: [github]
        )
        XCTAssertEqual(filtered.map(\.id), [link.id])
    }

    func testQueryFilterIsCaseInsensitive() {
        let entry = Fixture.text("发票报销 Invoice", hash: "q")
        XCTAssertTrue(entry.matches(query: "报销"))
        XCTAssertTrue(entry.matches(query: "invoice"))
        XCTAssertTrue(entry.matches(query: "   "), "blank query keeps the entry")
        XCTAssertFalse(entry.matches(query: "缺席"))
    }

    func testPercentWildcardSearchSupportsImplicitFuzzyEndsAndOrderedFragments() {
        let entry = Fixture.text("Invoice 2026 approved", hash: "percent")
        XCTAssertTrue(entry.matches(query: "invoice%approved"))
        XCTAssertTrue(entry.matches(query: "%2026%"))
        XCTAssertTrue(entry.matches(query: "%APPROVED"))
        XCTAssertTrue(entry.matches(query: "2026%"))
        XCTAssertTrue(entry.matches(query: "%invoice"))
        XCTAssertFalse(entry.matches(query: "approved%invoice"), "fragments must still appear in order")
    }
}
