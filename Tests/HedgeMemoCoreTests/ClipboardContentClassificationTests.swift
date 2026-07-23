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

    func testLongEnglishProseWithKeywordsIsNotCode() {
        // Trips "return"/"where"/"update" keywords and a parenthesis, but reads
        // as plain English — must not be classified as code.
        XCTAssertFalse(ClipboardCodeDetector.isCode(
            "Please return the package (the large one) to the front desk where you can update the records."
        ))
        XCTAssertFalse(ClipboardCodeDetector.isCode(
            "The class was great and I want to return to it, so please let me know when the next one is."
        ))
        XCTAssertFalse(ClipboardCodeDetector.isCode(
            "We are writing to confirm that your interface with the public records office has been updated."
        ))
    }

    func testLongEnglishWithIncidentalParensOrBracketsIsNotCode() {
        // A word-adjacent "results(" and a "[final]" pair used to read as hard
        // code structure; long English carrying them is still prose.
        XCTAssertFalse(ClipboardCodeDetector.isCode(
            "The report shows the results(2024) for the whole team, and the summary is in the shared notes."
        ))
        XCTAssertFalse(ClipboardCodeDetector.isCode(
            "Please review the list[final] and let me know what you think about the overall timeline for it."
        ))
    }

    func testLongTechnicalWorkLogWithEmbeddedCodeTermsIsNotCode() {
        // Representative of the attached execution log: it contains API names,
        // Markdown, arrows, command names and statement-like snippets, but the
        // dominant structure is a natural-language report rather than source.
        let workLog = """
        I'll work through these four tasks. Let me start by examining the relevant code for each.

        Let me check for existing crash reports to diagnose task 3 (the settings crash).
        There's a crash report. Let me examine it.
        A definitive crash. It's an uncaught ObjC exception during makeKeyAndOrderFront and a remote-view path.
        The crash is from an older Applications build. Let me inspect the generated Info.plist.

        ## 1. Animated preview collapse after saving an edit
        Replaced the abrupt disappearance with a fade and scale-out that plays while the panel is still expanded.

        ## 2. Resource-usage optimization
        - Background: the always-on pasteboard poll now sets `timer.tolerance = 0.25` for coalesced wakeups.
        - Foreground: `PanelMaterialHost` no longer creates a throwaway visual effect view on every body pass.
        - Verification: clean build, tests, layout self-check and whitebox all pass.

        One note on scope: the plist fix lives in build_and_run.sh. If you distribute through another path, add the same required key there.
        """
        XCTAssertFalse(ClipboardCodeDetector.isCode(workLog))
        XCTAssertEqual(Fixture.text(workLog, hash: "work-log").contentCategory, .text)
    }

    func testLongSourceWithCommentsRemainsCode() {
        let source = """
        // Build a stable result for the current user.
        // The comments intentionally contain ordinary English sentences.
        struct ResultBuilder {
            let values: [Int]

            func total() -> Int {
                values.reduce(0) { partial, value in
                    partial + value
                }
            }
        }
        """
        XCTAssertTrue(ClipboardCodeDetector.isCode(source))
    }

    func testCodeWithEnglishWordsButRealStructureIsStillCode() {
        // English words appear, but the structural markers are unmistakable.
        XCTAssertTrue(ClipboardCodeDetector.isCode("if (user.isActive) { return user.name; }"))
        XCTAssertTrue(ClipboardCodeDetector.isCode(
            """
            // return the total for the current user
            func total(for user: User) -> Int { user.items.count }
            """
        ))
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
