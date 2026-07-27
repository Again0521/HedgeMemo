import Foundation

/// Pure invalidation policy shared by the AppKit editor and core tests. When
/// none of the supported lexical constructs can cross a newline, re-highlighting
/// complete affected lines is equivalent to rescanning the whole document.
package enum CodeHighlightInvalidation {
    private static let crossLineMarkers = [
        "\"\"\"", "'''", "/*", "*/", "<!--", "-->", "r#",
    ]

    package static func supportsLineLocalHighlighting(_ text: String) -> Bool {
        !crossLineMarkers.contains { text.contains($0) }
    }

    package static func affectedLineRange(in text: String, editedRange: NSRange) -> NSRange {
        let nsText = text as NSString
        let fullLength = nsText.length
        guard fullLength > 0 else { return NSRange(location: 0, length: 0) }

        let editStart = min(editedRange.location, fullLength)
        let availableLength = fullLength - editStart
        let editLength = min(editedRange.length, availableLength)
        // Include one UTF-16 unit on either side. If the edit inserts or
        // removes a newline, both resulting neighboring lines can change their
        // lexical role and must be recolored together.
        let probeStart = editStart > 0 ? editStart - 1 : 0
        let editEnd = editStart + editLength
        let probeEnd = min(fullLength, editEnd + 1)
        return nsText.lineRange(for: NSRange(
            location: probeStart,
            length: max(0, probeEnd - probeStart)
        ))
    }
}
