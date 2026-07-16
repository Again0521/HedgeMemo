import CoreGraphics
import Foundation

/// Pure layout math for the clipboard panel so the AppKit panel controller and
/// the SwiftUI content agree on sizes, and the sizing rules stay testable.
public enum ClipboardPanelLayout {
    public static let panelWidth: CGFloat = 368
    public static let outerPadding: CGFloat = 12
    public static let headerHeight: CGFloat = 30
    public static let segmentedHeight: CGFloat = 24
    public static let sectionSpacing: CGFloat = 8

    public static let textRowHeight: CGFloat = 50
    public static let codeRowHeight: CGFloat = 76
    public static let listSpacing: CGFloat = 6

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

    public static func contentHeight(entryCount: Int, category: ClipboardContentCategory) -> CGFloat {
        guard entryCount > 0 else { return emptyStateHeight }
        switch category {
        case .text:
            return CGFloat(entryCount) * textRowHeight + CGFloat(entryCount - 1) * listSpacing
        case .code:
            return CGFloat(entryCount) * codeRowHeight + CGFloat(entryCount - 1) * listSpacing
        case .image:
            let rows = Int(ceil(Double(entryCount) / Double(imageColumns)))
            return CGFloat(rows) * imageCellSide + CGFloat(rows - 1) * imageCellSpacing
        }
    }

    /// Total panel height for the given content, clamped to the available screen height
    /// (callers pass the screen's visible frame height, which excludes menu bar and Dock).
    public static func panelHeight(
        entryCount: Int,
        category: ClipboardContentCategory,
        availableHeight: CGFloat
    ) -> CGFloat {
        let desired = chromeHeight + contentHeight(entryCount: entryCount, category: category)
        let minimum = chromeHeight + emptyStateHeight
        let maximum = max(minimum, availableHeight)
        return min(max(desired, minimum), maximum)
    }
}
