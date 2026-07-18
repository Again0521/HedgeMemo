import Foundation
import HedgeMemoCore
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

    static func highlight(_ code: String, theme: CodeHighlightTheme = .system) -> AttributedString {
        var attributed = AttributedString(code)
        let palette = Palette(theme: theme)
        attributed.foregroundColor = palette.plain
        let nsRange = NSRange(code.startIndex..., in: code)

        apply(typePattern, to: &attributed, in: code, range: nsRange, color: palette.type)
        apply(functionPattern, to: &attributed, in: code, range: nsRange, color: palette.function)
        apply(annotationPattern, to: &attributed, in: code, range: nsRange, color: palette.annotation)
        apply(keywordPattern, to: &attributed, in: code, range: nsRange, color: palette.keyword)
        apply(numberPattern, to: &attributed, in: code, range: nsRange, color: palette.number)
        // Strings and comments are applied last so tokens inside them are not
        // misleadingly colored as source code.
        apply(stringPattern, to: &attributed, in: code, range: nsRange, color: palette.string)
        apply(commentPattern, to: &attributed, in: code, range: nsRange, color: palette.comment)
        return attributed
    }

    private struct Palette {
        let plain: Color
        let type: Color
        let function: Color
        let annotation: Color
        let keyword: Color
        let number: Color
        let string: Color
        let comment: Color

        init(theme: CodeHighlightTheme) {
            switch theme {
            case .system:
                plain = .primary
                type = Color(nsColor: .systemTeal)
                function = Color(nsColor: .systemIndigo)
                annotation = Color(nsColor: .systemOrange)
                keyword = Color(nsColor: .systemPurple)
                number = Color(nsColor: .systemBlue)
                string = Color(nsColor: .systemRed)
                comment = .secondary
            case .xcodeLight:
                plain = Self.rgb(0x1F, 0x1F, 0x24)
                type = Self.rgb(0x0B, 0x70, 0x70)
                function = Self.rgb(0x32, 0x4F, 0xA1)
                annotation = Self.rgb(0x9B, 0x3B, 0x17)
                keyword = Self.rgb(0xA8, 0x13, 0x6D)
                number = Self.rgb(0x20, 0x4F, 0xC8)
                string = Self.rgb(0xC4, 0x1A, 0x16)
                comment = Self.rgb(0x6C, 0x72, 0x80)
            case .solarizedLight:
                plain = Self.rgb(0x58, 0x6E, 0x75)
                type = Self.rgb(0x26, 0x8B, 0xD2)
                function = Self.rgb(0x26, 0x8B, 0xD2)
                annotation = Self.rgb(0xB5, 0x89, 0x00)
                keyword = Self.rgb(0x85, 0x99, 0x00)
                number = Self.rgb(0xD3, 0x36, 0x82)
                string = Self.rgb(0x2A, 0xA1, 0x98)
                comment = Self.rgb(0x93, 0xA1, 0xA1)
            case .githubLight:
                plain = Self.rgb(0x24, 0x2D, 0x3D)
                type = Self.rgb(0x05, 0x5D, 0xB0)
                function = Self.rgb(0x82, 0x54, 0xE8)
                annotation = Self.rgb(0x95, 0x3B, 0x0E)
                keyword = Self.rgb(0xCF, 0x22, 0xE0)
                number = Self.rgb(0x05, 0x5D, 0xB0)
                string = Self.rgb(0x0A, 0x30, 0x6B)
                comment = Self.rgb(0x65, 0x6D, 0x76)
            }
        }

        private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
            Color(
                nsColor: NSColor(
                    calibratedRed: CGFloat(red) / 255,
                    green: CGFloat(green) / 255,
                    blue: CGFloat(blue) / 255,
                    alpha: 1
                )
            )
        }
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
