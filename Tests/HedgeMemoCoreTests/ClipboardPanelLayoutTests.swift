import CoreGraphics
import XCTest

@testable import HedgeMemoCore

final class ClipboardPanelLayoutTests: XCTestCase {
    /// The clipboard list was tightened: rows stay compact yet remain tall
    /// enough to read the 12-pt entry text without clipping.
    func testTextRowsStayCompactYetReadable() {
        XCTAssertTrue(
            (24...28).contains(ClipboardPanelLayout.textRowHeight),
            "text rows must stay compact yet readable"
        )
    }

    // MARK: - Preview width balancing

    private let cap: CGFloat = 360

    func testShortTextKeepsItsNaturalNarrowWidth() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 120, cap: cap),
            120,
            "short text must keep its natural, narrow width"
        )
    }

    func testTextExactlyAtCapStaysOnOneLine() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: cap, cap: cap),
            cap,
            "text exactly at the cap must stay on one line"
        )
    }

    func testTextJustOverCapSplitsIntoTwoEvenLines() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 480, cap: cap),
            240,
            "text just over the cap must split into two evenly filled lines"
        )
    }

    func testLongTextBalancesWithoutLonelyTail() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 1200, cap: cap),
            300,
            "long text must balance across the fewest capped lines, not leave a lonely tail"
        )
    }

    func testVeryLongTextFillsEachLineToTheCap() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 1800, cap: cap),
            cap,
            "very long text must fill each line up to the readable cap"
        )
    }

    func testWrappedLineNeverExceedsTheCap() {
        XCTAssertLessThanOrEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 5000, cap: cap),
            cap,
            "a wrapped preview line must never exceed the readable cap"
        )
    }

    func testHardWrappedSnippetKeepsItsWidestExistingLine() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(
                singleLineWidth: 120, cap: cap, longestHardLineWidth: 300, hasHardBreaks: true
            ),
            300,
            "a hard-wrapped snippet must stay at least as wide as its widest existing line"
        )
    }

    func testHardLineWiderThanCapClampsToCap() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(
                singleLineWidth: 120, cap: cap, longestHardLineWidth: 900, hasHardBreaks: true
            ),
            cap,
            "a hard line wider than the cap must clamp to the readable cap"
        )
    }

    func testNonPositiveCapDegradesToUnwrappedWidth() {
        XCTAssertEqual(
            ClipboardPanelLayout.balancedPreviewContentWidth(singleLineWidth: 400, cap: 0),
            400,
            "a non-positive cap must degrade to the unwrapped width without dividing by zero"
        )
    }
}
