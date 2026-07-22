import CoreGraphics
import XCTest

@testable import HedgeMemoCore

final class ClipboardPanelLayoutTests: XCTestCase {
    // MARK: - Row metrics

    /// The clipboard list was tightened: rows stay compact yet remain tall
    /// enough to read the 12-pt entry text without clipping.
    func testTextRowsStayCompactYetReadable() {
        XCTAssertTrue(
            (24...28).contains(ClipboardPanelLayout.textRowHeight),
            "text rows must stay compact yet readable"
        )
    }

    func testChromeAndImageCellAreProportioned() {
        XCTAssertGreaterThan(ClipboardPanelLayout.chromeHeight, 0)
        XCTAssertGreaterThan(ClipboardPanelLayout.imageCellSide, 0)
        // Three columns plus their gaps must fit inside the panel body.
        let used = ClipboardPanelLayout.imageCellSide * 3
            + ClipboardPanelLayout.imageCellSpacing * 2
            + ClipboardPanelLayout.outerPadding * 2
        XCTAssertLessThanOrEqual(used, ClipboardPanelLayout.panelWidth + 1)
    }

    // MARK: - Preview width balancing

    private let cap: CGFloat = 360

    func testShortTextKeepsItsNaturalNarrowWidth() {
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 120, cap: cap), 120)
    }

    func testTextExactlyAtCapStaysOnOneLine() {
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: cap, cap: cap), cap)
    }

    func testTextJustOverCapSplitsIntoTwoEvenLines() {
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 480, cap: cap), 240)
    }

    func testLongTextBalancesWithoutLonelyTail() {
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 1200, cap: cap), 300)
    }

    func testVeryLongTextFillsEachLineToTheCap() {
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 1800, cap: cap), cap)
    }

    func testWrappedLineNeverExceedsTheCap() {
        XCTAssertLessThanOrEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 5000, cap: cap), cap)
    }

    func testHardWrappedSnippetKeepsItsWidestExistingLine() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(
                singleLineWidth: 120, cap: cap, longestHardLineWidth: 300, hasHardBreaks: true
            ),
            300
        )
    }

    func testHardLineWiderThanCapClampsToCap() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(
                singleLineWidth: 120, cap: cap, longestHardLineWidth: 900, hasHardBreaks: true
            ),
            cap
        )
    }

    func testNonPositiveCapDegradesToUnwrappedWidth() {
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 400, cap: 0), 400)
        XCTAssertEqual(ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: -5, cap: 0), 0)
    }

    // MARK: - Code preview line extraction

    func testSingleLineCountsAsOnePreviewLine() {
        XCTAssertEqual(ClipboardPanelLayout.previewLineCount("single line"), 1)
    }

    func testPreviewClampsToThreeLines() {
        XCTAssertEqual(ClipboardPanelLayout.previewLineCount("a\nb\nc\nd\ne"), 3)
    }

    func testBlankCodeLinesReserveNoPhantomRows() {
        XCTAssertEqual(ClipboardPanelLayout.codePreviewLines("one\n\n\n"), ["one"])
    }

    func testEmptyTextStillYieldsOneEmptyPreviewLine() {
        XCTAssertEqual(ClipboardPanelLayout.codePreviewLines(nil), [""])
        XCTAssertEqual(ClipboardPanelLayout.previewLineCount(""), 1)
    }

    func testOversizedSingleLineKeepsOnlyItsVisiblePrefix() {
        let code = String(repeating: "x", count: ClipboardPanelLayout.codePreviewLineCharacterLimit * 20)
        XCTAssertEqual(
            ClipboardPanelLayout.codePreviewLines(code),
            [String(repeating: "x", count: ClipboardPanelLayout.codePreviewLineCharacterLimit)]
        )
    }

    func testCodeRowHeightGrowsWithLineCountThenClamps() {
        XCTAssertLessThan(
            ClipboardPanelLayout.codeRowHeight(lineCount: 1),
            ClipboardPanelLayout.codeRowHeight(lineCount: 3)
        )
        // Beyond the preview maximum the row height must not keep growing.
        XCTAssertEqual(
            ClipboardPanelLayout.codeRowHeight(lineCount: 9),
            ClipboardPanelLayout.codeRowHeight(lineCount: ClipboardPanelLayout.codePreviewMaxLines)
        )
        // A zero/negative count still reserves a single line.
        XCTAssertEqual(
            ClipboardPanelLayout.codeRowHeight(lineCount: 0),
            ClipboardPanelLayout.codeRowHeight(lineCount: 1)
        )
    }

    // MARK: - Content height per category

    func testEmptyCategoryKeepsEmptyStateHeight() {
        XCTAssertEqual(
            ClipboardPanelLayout.contentHeight(for: [], key: .builtin(.text)),
            ClipboardPanelLayout.emptyStateHeight
        )
    }

    func testTextContentHeightFollowsRowCount() {
        let rows = [Fixture.text("一"), Fixture.text("二"), Fixture.text("三")]
        XCTAssertEqual(
            ClipboardPanelLayout.contentHeight(for: rows, key: .builtin(.text)),
            ClipboardPanelLayout.textRowHeight * 3 + ClipboardPanelLayout.listSpacing * 2
        )
    }

    func testImagesLayOutAsGridRows() {
        let images = (0..<4).map { Fixture.image(hash: "i\($0)") }
        XCTAssertEqual(
            ClipboardPanelLayout.contentHeight(for: images, key: .builtin(.image)),
            ClipboardPanelLayout.imageCellSide * 2 + ClipboardPanelLayout.imageCellSpacing
        )
    }

    func testCodeContentHeightFollowsPerEntryLineCounts() {
        let shortCode = Fixture.text("let a = 1;", hash: "c1")
        XCTAssertEqual(
            ClipboardPanelLayout.contentHeight(for: [shortCode], key: .builtin(.code)),
            ClipboardPanelLayout.codeRowHeight(lineCount: 1)
        )
    }

    // MARK: - Panel height & vertical placement

    func testPanelHeightClampsToAvailableScreen() {
        XCTAssertEqual(ClipboardPanelLayout.panelHeight(contentHeight: 10_000, availableHeight: 600), 600)
    }

    func testPanelHeightKeepsSensibleMinimum() {
        XCTAssertEqual(
            ClipboardPanelLayout.panelHeight(contentHeight: 0, availableHeight: 600),
            ClipboardPanelLayout.chromeHeight + ClipboardPanelLayout.emptyStateHeight
        )
    }

    func testTallCategoryStaysInsideVisibleScreen() {
        XCTAssertEqual(
            ClipboardPanelLayout.constrainedOriginY(
                preferredTop: 760, height: 600, visibleMinY: 100, visibleMaxY: 760
            ),
            148
        )
    }

    func testShortCategoryPreservesPriorTopEdge() {
        XCTAssertEqual(
            ClipboardPanelLayout.constrainedOriginY(
                preferredTop: 400, height: 200, visibleMinY: 100, visibleMaxY: 760
            ),
            200
        )
    }
}
