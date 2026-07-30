import XCTest

@testable import HedgeMemoCore

final class RuntimeCacheTests: XCTestCase {
    override func tearDown() {
        ClipboardRuntimeCaches.removeAll()
        super.tearDown()
    }

    func testClassificationCacheCanBeReleasedWithoutChangingResult() {
        let text = "func render(value: Int) -> String { String(value) }"
        let before = TextCategoryCache.shared.category(
            contentHash: "runtime-cache-classification",
            text: text
        )

        XCTAssertGreaterThan(TextCategoryCache.shared.entryCount, 0)

        ClipboardRuntimeCaches.removeAll()
        XCTAssertEqual(TextCategoryCache.shared.entryCount, 0)
        XCTAssertEqual(
            TextCategoryCache.shared.category(
                contentHash: "runtime-cache-classification",
                text: text
            ),
            before
        )
    }

    func testRegexCacheCanBeReleasedWithoutChangingRuleMatching() {
        let category = CustomClipboardCategory(name: "Swift", pattern: "func\\s+\\w+")
        XCTAssertTrue(category.matches("public func render() {}"))

        ClipboardRuntimeCaches.removeAll()

        XCTAssertTrue(category.matches("public func render() {}"))
        XCTAssertFalse(category.matches("let render = true"))
    }
}
