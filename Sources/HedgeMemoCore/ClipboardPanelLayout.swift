import CoreGraphics
import Foundation

/// Pure layout math for the clipboard panel so the AppKit panel controller and
/// the SwiftUI content agree on sizes, and the sizing rules stay testable.
public enum ClipboardPanelLayout {
    /// A little wider than the original list so ordinary source lines and
    /// long filenames do not truncate prematurely.  The extra 60 pt is about
    /// five CJK characters at the panel's standard body size.
    public static let panelWidth: CGFloat = 460
    public static let outerPadding: CGFloat = 12
    public static let headerHeight: CGFloat = 28
    public static let segmentedHeight: CGFloat = 22
    public static let sectionSpacing: CGFloat = 8

    public static let textRowHeight: CGFloat = 27
    public static let listSpacing: CGFloat = 0

    public static let codeLineHeight: CGFloat = 14
    public static let codeRowPadding: CGFloat = 8
    public static let codePreviewMaxLines = 3
    public static let codeSeparatorHeight: CGFloat = 1

    public static let imageColumns = 3
    public static let imageCellSpacing: CGFloat = 8
    public static let emptyStateHeight: CGFloat = 150

    /// Chrome above the scrolling content: paddings, search field, category switcher.
    public static var chromeHeight: CGFloat {
        outerPadding + headerHeight + sectionSpacing + segmentedHeight + sectionSpacing + outerPadding
    }

    public static var imageCellSide: CGFloat {
        let content = panelWidth - outerPadding * 2 - imageCellSpacing * CGFloat(imageColumns - 1)
        return (content / CGFloat(imageColumns)).rounded(.down)
    }

    /// A preview line never displays more than a row's width; the cap keeps a
    /// single enormous pasted line from making SwiftUI lay out megabytes.
    public static let codePreviewLineCharacterLimit = 600

    /// Returns only lines that contain content. This makes "at most three
    /// lines" literal: a one-line snippet occupies one row, while blank
    /// separator lines never reserve phantom height.
    ///
    /// Scans lazily and stops at the third content line: this runs from
    /// scrolling list rows, and splitting an entire large clipboard text on
    /// every row render was a measurable scroll cost.
    public static func codePreviewLines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [""] }
        var lines: [String] = []
        var line = String()
        line.reserveCapacity(codePreviewLineCharacterLimit)
        var collectedCount = 0
        var containsVisibleCharacter = false

        for character in text {
            if character.isNewline {
                if containsVisibleCharacter {
                    lines.append(line)
                    if lines.count == codePreviewMaxLines { return lines }
                }
                line.removeAll(keepingCapacity: true)
                collectedCount = 0
                containsVisibleCharacter = false
                continue
            }

            if collectedCount < codePreviewLineCharacterLimit {
                line.append(character)
                collectedCount += 1
            }
            if !character.isWhitespace {
                containsVisibleCharacter = true
            }
            // The rest of an oversized source line cannot be displayed by
            // this row. Returning as soon as its visible prefix is full is
            // important for minified JSON/source: the old newline search
            // walked a multi-megabyte line just to throw the suffix away.
            if collectedCount == codePreviewLineCharacterLimit, containsVisibleCharacter {
                lines.append(line)
                return lines
            }
        }
        if containsVisibleCharacter { lines.append(line) }
        return lines.isEmpty ? [""] : lines
    }

    public static func previewLineCount(_ text: String?) -> Int {
        codePreviewLines(text).count
    }

    public static func codeRowHeight(lineCount: Int) -> CGFloat {
        let lines = min(max(lineCount, 1), codePreviewMaxLines)
        return codeRowPadding + CGFloat(lines) * codeLineHeight
    }

    /// Chooses the content width for a wrapped text preview so it neither leaves
    /// a wide blank margin beside a short snippet nor squashes long text into an
    /// unreadable single line.  All widths are point measurements of the same
    /// font: `singleLineWidth` is how wide the text is with no wrapping, `cap`
    /// the widest a line may become.  Long text is spread over the fewest lines
    /// that keep each at or below `cap`, then evened out so the final line is
    /// not a lonely tail.  A snippet already broken by hard newlines is never
    /// wrapped narrower than its widest existing line (up to `cap`).
    public static func balancedPreviewContentWidth(
        singleLineWidth: CGFloat,
        cap: CGFloat,
        longestHardLineWidth: CGFloat = 0,
        hasHardBreaks: Bool = false
    ) -> CGFloat {
        guard cap > 0 else { return max(0, singleLineWidth) }
        var content: CGFloat
        if singleLineWidth <= cap {
            content = max(0, singleLineWidth)
        } else {
            let lines = (singleLineWidth / cap).rounded(.up)
            content = (singleLineWidth / lines).rounded(.up)
        }
        if hasHardBreaks {
            content = max(content, min(longestHardLineWidth, cap))
        }
        return min(cap, content)
    }

    /// Height of the scrolling content for the given entries in a category.
    public static func contentHeight(for entries: [ClipboardEntry], key: ClipboardCategoryKey?) -> CGFloat {
        guard !entries.isEmpty else { return emptyStateHeight }
        switch key {
        case .builtin(.image), .builtin(.screenshot):
            let rows = Int(ceil(Double(entries.count) / Double(imageColumns)))
            return CGFloat(rows) * imageCellSide + CGFloat(rows - 1) * imageCellSpacing
        case .builtin(.code):
            let rows = entries.map { codeRowHeight(lineCount: previewLineCount($0.text)) }
            return rows.reduce(0, +) + CGFloat(entries.count - 1) * codeSeparatorHeight
        default:
            return CGFloat(entries.count) * textRowHeight + CGFloat(entries.count - 1) * listSpacing
        }
    }

    /// Total panel height, clamped to the available screen height (callers pass
    /// the screen's visible frame height, which excludes menu bar and Dock).
    public static func panelHeight(contentHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let desired = chromeHeight + contentHeight
        let minimum = chromeHeight + emptyStateHeight
        let maximum = max(minimum, availableHeight)
        return min(max(desired, minimum), maximum)
    }

    /// Keeps a resizable panel entirely inside the visible part of a screen.
    /// The old top edge is retained whenever possible. If a category is taller
    /// than the space below it, the panel moves upward instead of letting the
    /// search field disappear above the menu bar.
    public static func constrainedOriginY(
        preferredTop: CGFloat,
        height: CGFloat,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat,
        inset: CGFloat = 12
    ) -> CGFloat {
        let minimum = visibleMinY + inset
        let maximum = max(minimum, visibleMaxY - inset - height)
        let preferred = min(preferredTop, visibleMaxY - inset) - height
        return min(max(preferred, minimum), maximum)
    }
}

/// Incremental rendering policy for the two expensive clipboard surfaces.
/// Text/link rows stay fully enumerated because they are cheap; code rows incur
/// syntax highlighting and image cells may schedule a decode, so those lists
/// grow in bounded pages as their current tail becomes visible.
public enum ClipboardPanelPagination {
    public static let codePageSize = 60
    public static let imagePageSize = 48

    public static func pageSize(for key: ClipboardCategoryKey?) -> Int? {
        switch key {
        case .builtin(.code): codePageSize
        case .builtin(.image), .builtin(.screenshot): imagePageSize
        default: nil
        }
    }

    public static func initialLimit(for key: ClipboardCategoryKey?) -> Int {
        pageSize(for: key) ?? Int.max
    }

    public static func nextLimit(current: Int, total: Int, key: ClipboardCategoryKey?) -> Int {
        guard let pageSize = pageSize(for: key) else { return total }
        return min(total, max(current, 0) + pageSize)
    }

    /// How many cells before the loaded tail should trigger the next page.
    /// Prefetching a quarter-page early means the scroll never pauses at a page
    /// boundary waiting for the list to grow, so paging stays invisible.
    public static func prefetchDistance(for key: ClipboardCategoryKey?) -> Int {
        guard let pageSize = pageSize(for: key) else { return 0 }
        return max(1, pageSize / 4)
    }
}
