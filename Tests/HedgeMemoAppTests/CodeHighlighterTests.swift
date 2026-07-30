import AppKit
import XCTest

@testable import HedgeMemo

final class CodeHighlighterTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func testIncrementalIdentifierEditMatchesFullHighlightExactly() {
        assertIncrementalMatchesFull(
            initial: """
            let inputValue = parse(input)
            // keep this line unchanged
            return inputValue + 42
            """,
            replacing: "inputValue",
            with: "outputValue"
        )
    }

    func testIncrementalNewlineInsertionMatchesFullHighlightExactly() {
        assertIncrementalMatchesFull(
            initial: "let result = parse(input)\nreturn result",
            replacing: " = ",
            with: "\n= "
        )
    }

    func testIncrementalNewlineDeletionMatchesFullHighlightExactly() {
        assertIncrementalMatchesFull(
            initial: "let result\n= parse(input)\nreturn result",
            replacing: "\n",
            with: " "
        )
    }

    func testReleasingHighlightCacheDoesNotChangeRenderedAttributes() {
        let code = "struct Result { let value = parse(\"42\") // stable }"
        let before = CodeHighlighter.highlight(code, theme: .githubLight)
        CodeHighlighter.releaseTransientCache()
        let after = CodeHighlighter.highlight(code, theme: .githubLight)

        XCTAssertEqual(before, after)
    }

    private func assertIncrementalMatchesFull(
        initial: String,
        replacing needle: String,
        with replacement: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let initialStorage = NSTextStorage(string: initial)
        CodeHighlighter.applyHighlighting(
            to: initialStorage,
            baseFont: font,
            theme: .system
        )

        let replacementRange = (initial as NSString).range(of: needle)
        XCTAssertNotEqual(replacementRange.location, NSNotFound, file: file, line: line)
        let incremental = NSTextStorage(attributedString: initialStorage)
        incremental.replaceCharacters(in: replacementRange, with: replacement)
        CodeHighlighter.applyHighlighting(
            to: incremental,
            baseFont: font,
            theme: .system,
            editedRange: NSRange(
                location: replacementRange.location,
                length: (replacement as NSString).length
            )
        )

        let expected = NSTextStorage(string: incremental.string)
        CodeHighlighter.applyHighlighting(
            to: expected,
            baseFont: font,
            theme: .system
        )
        XCTAssertTrue(
            incremental.isEqual(to: expected),
            "incremental attributes diverged from a full highlight",
            file: file,
            line: line
        )
    }
}
