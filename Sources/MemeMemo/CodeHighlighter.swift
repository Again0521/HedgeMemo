import SwiftUI

/// Regex-based highlighter for clipboard code previews. Not a real parser —
/// it colors the token classes that make a snippet scan like an editor:
/// comments, strings, numbers, and common keywords.
enum CodeHighlighter {
    private static let keywordPattern: NSRegularExpression = {
        let keywords = [
            "func", "function", "class", "struct", "enum", "interface", "extension",
            "def", "return", "import", "from", "package", "include", "define",
            "var", "let", "const", "static", "public", "private", "protected", "internal",
            "if", "else", "elif", "for", "while", "switch", "case", "default", "break", "continue",
            "guard", "in", "do", "try", "catch", "throw", "throws", "async", "await", "yield",
            "new", "self", "this", "super", "nil", "null", "true", "false", "void", "int",
            "string", "bool", "double", "float", "select", "insert", "update", "delete", "where",
        ]
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let stringPattern = try! NSRegularExpression(
        pattern: "\"[^\"\\n]*\"|'[^'\\n]*'|`[^`\\n]*`"
    )
    private static let commentPattern = try! NSRegularExpression(
        pattern: "//[^\\n]*|#[^\\n]*|/\\*.*?\\*/",
        options: [.dotMatchesLineSeparators]
    )
    private static let numberPattern = try! NSRegularExpression(
        pattern: "\\b\\d+(?:\\.\\d+)?\\b"
    )

    static func highlight(_ code: String) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = .primary
        let nsRange = NSRange(code.startIndex..., in: code)

        apply(keywordPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemPurple))
        apply(numberPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemBlue))
        apply(stringPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemRed))
        apply(commentPattern, to: &attributed, in: code, range: nsRange, color: .secondary)
        return attributed
    }

    private static func apply(
        _ regex: NSRegularExpression,
        to attributed: inout AttributedString,
        in code: String,
        range: NSRange,
        color: Color
    ) {
        for match in regex.matches(in: code, range: range) {
            guard let swiftRange = Range(match.range, in: code),
                  let attributedRange = Range(swiftRange, in: attributed) else { continue }
            attributed[attributedRange].foregroundColor = color
        }
    }
}
