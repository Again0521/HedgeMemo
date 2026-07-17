import Foundation
import SwiftUI

/// Lightweight, language-agnostic highlighting for clipboard previews. It is
/// deliberately token based (a clipboard has no reliable file extension), but
/// covers the lexical classes shared by Swift, Java, Kotlin, JavaScript,
/// TypeScript, Python, JSON, SQL and shell snippets.
enum CodeHighlighter {
    private static let keywordPattern: NSRegularExpression = {
        let keywords = [
            "func", "function", "class", "struct", "enum", "interface", "extension", "protocol", "actor",
            "typealias", "associatedtype", "init", "deinit", "def", "return", "import", "from", "package",
            "include", "define", "module", "namespace", "using", "var", "let", "const", "static", "public",
            "private", "protected", "internal", "fileprivate", "open", "final", "override", "mutating",
            "nonmutating", "if", "else", "elif", "for", "foreach", "while", "repeat", "until", "switch",
            "case", "default", "break", "continue", "fallthrough", "guard", "where", "in", "do", "defer",
            "try", "catch", "throw", "throws", "rethrows", "async", "await", "yield", "lambda", "with",
            "new", "self", "this", "super", "nil", "null", "undefined", "true", "false", "void", "int",
            "string", "bool", "double", "float", "byte", "short", "long", "char", "any", "some", "as", "is",
            "instanceof", "implements", "extends", "abstract", "synchronized", "volatile", "transient", "native",
            "val", "fun", "object", "data", "sealed", "when", "select", "insert", "update", "delete", "into",
            "values", "join", "on", "group", "by", "order", "limit", "create", "alter", "drop", "table",
        ]
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let stringPattern = try! NSRegularExpression(
        pattern: ##"(?:[rubfRUBF]{0,2}(?:"""[\s\S]*?"""|'''[\s\S]*?'''))|(?:r#+"[\s\S]*?"#+)|(?:"(?:\\.|[^"\\\n])*")|(?:'(?:\\.|[^'\\\n])*')|(?:`(?:\\.|[^`\\\n])*`)"##
    )
    private static let commentPattern = try! NSRegularExpression(
        pattern: "//[^\\n]*|#[^\\n]*|--[^\\n]*|/\\*.*?\\*/|<!--.*?-->",
        options: [.dotMatchesLineSeparators]
    )
    private static let numberPattern = try! NSRegularExpression(
        pattern: "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:\\d[\\d_]*)(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
    )
    private static let typePattern = try! NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]*(?:<[^>\\n]+>)?\\b")
    private static let functionPattern = try! NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*(?=\\s*\\()")
    private static let annotationPattern = try! NSRegularExpression(pattern: "(?:@|#)\\w+")

    static func highlight(_ code: String) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = .primary
        let nsRange = NSRange(code.startIndex..., in: code)

        apply(typePattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemTeal))
        apply(functionPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemIndigo))
        apply(annotationPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemOrange))
        apply(keywordPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemPurple))
        apply(numberPattern, to: &attributed, in: code, range: nsRange, color: Color(nsColor: .systemBlue))
        // Strings and comments are applied last so tokens inside them are not
        // misleadingly colored as source code.
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
