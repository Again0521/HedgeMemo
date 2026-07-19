import XCTest

@testable import HedgeMemoCore

/// Covers the heuristics that sort a pasted string into text / code / link /
/// image / screenshot buckets.
final class ClipboardContentClassificationTests: XCTestCase {
    // MARK: - Code detection

    func testMultiLineSourceIsCode() {
        let snippet = """
        func greet(name: String) -> String {
            return "hi " + name
        }
        """
        XCTAssertTrue(ClipboardCodeDetector.isCode(snippet))
    }

    func testSingleLineStatementIsCode() {
        XCTAssertTrue(ClipboardCodeDetector.isCode("const total = items.reduce((a, b) => a + b, 0);"))
    }

    func testProseIsNotCode() {
        XCTAssertFalse(ClipboardCodeDetector.isCode("今天下午三点开会，请准时参加。"))
        XCTAssertFalse(ClipboardCodeDetector.isCode("Let's meet at 3pm."))
    }

    func testBareLinkIsNotCode() {
        XCTAssertFalse(ClipboardCodeDetector.isCode("https://github.com/Again0521/hedgememo"))
    }

    func testTooShortStringIsNotCode() {
        XCTAssertFalse(ClipboardCodeDetector.isCode("a=1;"))
    }

    func testCJKHeavyStringIsNotCode() {
        // Braces and a keyword, but overwhelmingly Chinese — should read as prose.
        XCTAssertFalse(ClipboardCodeDetector.isCode("如果 { 今天下午我们要开一个很长很长的会议讨论所有的事情 }"))
    }

    // MARK: - Link detection

    func testCommonSchemesAndDomainsAreLinks() {
        for candidate in [
            "https://example.com",
            "http://example.com/path?q=1",
            "ftp://files.example.com",
            "mailto:hi@example.com",
            "www.example.com/path",
            "example.com",
            "sub.domain.co/path",
        ] {
            XCTAssertTrue(ClipboardLinkDetector.isLink(candidate), "\(candidate) should be a link")
        }
    }

    func testStringsWithSpacesOrNewlinesAreNotLinks() {
        XCTAssertFalse(ClipboardLinkDetector.isLink("今天 example 下午三点"))
        XCTAssertFalse(ClipboardLinkDetector.isLink("visit example.com now"))
        XCTAssertFalse(ClipboardLinkDetector.isLink("line1\nexample.com"))
        XCTAssertFalse(ClipboardLinkDetector.isLink(""))
        XCTAssertFalse(ClipboardLinkDetector.isLink("just prose without a dot"))
    }

    func testLinkDetectionTrimsSurroundingWhitespace() {
        XCTAssertTrue(ClipboardLinkDetector.isLink("  https://example.com  "))
    }

    // MARK: - Entry categorisation

    func testEntryContentCategory() {
        XCTAssertEqual(Fixture.text("let a = 1;\nfunc f() {}").contentCategory, .code)
        XCTAssertEqual(Fixture.text("周五下班一起吃饭").contentCategory, .text)
        XCTAssertEqual(Fixture.text("https://github.com/Again0521/hedgememo").contentCategory, .link)
        XCTAssertEqual(Fixture.image(hash: "img").contentCategory, .image)
    }

    func testScreenshotOriginOverridesImageCategory() {
        XCTAssertEqual(
            Fixture.image(hash: "shot", origin: .hedgeMemoScreenshot).contentCategory,
            .screenshot
        )
    }

    // MARK: - Preview text

    func testPreviewTextFallbacks() {
        XCTAssertEqual(Fixture.text("   ").previewText, "空白文字")
        XCTAssertEqual(Fixture.text("  hi  ").previewText, "hi")
        let bareImage = ClipboardEntry(kind: .image, imageFileName: "x.png", contentHash: "x")
        XCTAssertEqual(bareImage.previewText, "图片")
    }

    // MARK: - Display metadata

    func testEveryBuiltinCategoryHasLabelAndSymbol() {
        for category in ClipboardContentCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }
}
