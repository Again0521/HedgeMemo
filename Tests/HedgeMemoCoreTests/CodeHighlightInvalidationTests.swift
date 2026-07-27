import Foundation
import XCTest

@testable import HedgeMemoCore

final class CodeHighlightInvalidationTests: XCTestCase {
    func testOrdinaryCodeCanInvalidateOnlyAffectedLines() {
        XCTAssertTrue(CodeHighlightInvalidation.supportsLineLocalHighlighting(
            "let value = parse(input)\n// one-line comment\nreturn value"
        ))
    }

    func testEveryCrossLineLexicalConstructForcesFullInvalidation() {
        let samples = [
            "let value = \"\"\"multiline\"\"\"",
            "value = '''multiline'''",
            "/* block comment */",
            "<!-- HTML comment -->",
            "let raw = r#\"value\"#",
        ]
        for sample in samples {
            XCTAssertFalse(
                CodeHighlightInvalidation.supportsLineLocalHighlighting(sample),
                "expected full invalidation for \(sample)"
            )
        }
    }

    func testAffectedRangeExpandsToWholeEditedLines() {
        let text = "let first = 1\nlet second = 2\nreturn second\n"
        let secondLine = (text as NSString).range(of: "second")
        XCTAssertEqual(
            CodeHighlightInvalidation.affectedLineRange(in: text, editedRange: secondLine),
            (text as NSString).range(of: "let second = 2\n")
        )
    }

    func testDeletionAtLineBoundaryInvalidatesMergedLine() {
        let textAfterDeletion = "let first = 1return second\n"
        let boundary = ("let first = 1" as NSString).length
        XCTAssertEqual(
            CodeHighlightInvalidation.affectedLineRange(
                in: textAfterDeletion,
                editedRange: NSRange(location: boundary, length: 0)
            ),
            NSRange(location: 0, length: (textAfterDeletion as NSString).length)
        )
    }

    func testInsertedNewlineInvalidatesBothResultingLines() {
        let textAfterInsertion = "let value\n= parse(input)\nreturn value\n"
        let newline = (textAfterInsertion as NSString).range(of: "\n")
        XCTAssertEqual(
            CodeHighlightInvalidation.affectedLineRange(
                in: textAfterInsertion,
                editedRange: newline
            ),
            (textAfterInsertion as NSString).range(of: "let value\n= parse(input)\n")
        )
    }
}
