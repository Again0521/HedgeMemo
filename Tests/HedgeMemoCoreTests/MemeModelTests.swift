import XCTest

@testable import HedgeMemoCore

/// Covers meme search matching and the `MemeFilter` category/query/order rules.
final class MemeModelTests: XCTestCase {
    func testNoteAndOCRAreSearchable() {
        let note = Fixture.meme("周五下班", hash: "a")
        let ocr = Fixture.meme("未命名", hash: "b", ocr: "你好世界")
        XCTAssertTrue(note.matches(query: "下班"))
        XCTAssertTrue(ocr.matches(query: "世界"))
        XCTAssertFalse(note.matches(query: "世界"))
    }

    func testBlankQueryMatchesEverythingAndSearchIsCaseInsensitive() {
        let meme = Fixture.meme("Hello", hash: "h")
        XCTAssertTrue(meme.matches(query: "   "))
        XCTAssertTrue(meme.matches(query: "hello"))
    }

    func testPercentWildcardSearchesNoteAndOCR() {
        let note = Fixture.meme("release-candidate-final", hash: "percent-note")
        let ocr = Fixture.meme("未命名", hash: "percent-ocr", ocr: "订单 2026 已完成")

        XCTAssertTrue(note.matches(query: "release%final"))
        XCTAssertTrue(note.matches(query: "%candidate%"))
        XCTAssertTrue(note.matches(query: "candidate%"), "queries are implicitly fuzzy at both ends")
        XCTAssertTrue(note.matches(query: "lease%final"))
        XCTAssertTrue(ocr.matches(query: "%2026%完成"))
    }

    func testCategoryFilterPreservesSortOrder() {
        let category = UUID()
        let first = Fixture.meme("一", hash: "1", category: category, sortOrder: 0)
        let second = Fixture.meme("二", hash: "2", category: category, sortOrder: 1)
        let other = Fixture.meme("外", hash: "3")
        XCTAssertEqual(
            MemeFilter.apply([second, other, first], categoryID: category, query: "").map(\.note),
            ["一", "二"]
        )
    }

    func testNilCategoryReturnsEveryMemeSorted() {
        let a = Fixture.meme("a", hash: "a", sortOrder: 1)
        let b = Fixture.meme("b", hash: "b", sortOrder: 0)
        XCTAssertEqual(MemeFilter.apply([a, b], categoryID: nil, query: "").map(\.note), ["b", "a"])
    }

    func testEqualSortOrderFallsBackToCreationTime() {
        let earlier = Fixture.meme("早", hash: "e", sortOrder: 5, at: 0)
        let later = Fixture.meme("晚", hash: "l", sortOrder: 5, at: 100)
        XCTAssertEqual(
            MemeFilter.apply([later, earlier], categoryID: nil, query: "").map(\.note),
            ["早", "晚"]
        )
    }

    func testQueryAndCategoryFilterCombine() {
        let category = UUID()
        let match = Fixture.meme("报销单", hash: "m", category: category, sortOrder: 0)
        let wrongCategory = Fixture.meme("报销单", hash: "w", sortOrder: 0)
        let wrongNote = Fixture.meme("聚餐", hash: "n", category: category, sortOrder: 1)
        XCTAssertEqual(
            MemeFilter.apply([match, wrongCategory, wrongNote], categoryID: category, query: "报销").map(\.id),
            [match.id]
        )
    }
}
