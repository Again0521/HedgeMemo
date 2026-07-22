import XCTest

@testable import HedgeMemoCore

/// Covers the inline code-completion ranking: document words first, and
/// case-insensitive "smart case" matching.
final class InlineCodeCompletionTests: XCTestCase {
    private let keywords = ["function", "return", "guard", "public", "private"]

    private func completion(_ partial: String, in text: String) -> String? {
        InlineCodeCompletion.completion(
            partial: partial,
            tokens: InlineCodeCompletion.tokens(in: text),
            keywords: keywords
        )
    }

    // MARK: - Tokenizing

    func testTokensCountAndOrderIdentifiers() {
        let tokens = InlineCodeCompletion.tokens(in: "let userName = user_id + userName // 3.14")
        XCTAssertEqual(tokens.order, ["let", "userName", "user_id"])
        XCTAssertEqual(tokens.counts["userName"], 2)
        XCTAssertEqual(tokens.counts["user_id"], 1)
        // A bare number is not an identifier token.
        XCTAssertNil(tokens.counts["3"])
    }

    // MARK: - Document words take priority

    func testCompletesToAWordAlreadyInTheText() {
        // "getUserName" is defined earlier; typing its prefix completes to it,
        // not to any keyword.
        XCTAssertEqual(completion("getU", in: "func getUserName() {}\n  getU"), "getUserName")
    }

    func testDocumentWordBeatsAKeyword() {
        // "func" would keyword-complete to "function", but a real identifier
        // "funcHelper" exists in the text and wins.
        XCTAssertEqual(completion("func", in: "funcHelper()\nfunc"), "funcHelper")
    }

    func testFallsBackToKeywordWhenNoDocumentWordMatches() {
        XCTAssertEqual(completion("retu", in: "let x = 1\nretu"), "return")
    }

    // MARK: - Smart case

    func testLowercasePrefixMatchesMixedCaseIdentifier() {
        // The whole point: typing lowercase still finds the camelCase word, and
        // the result keeps the identifier's real casing so accepting corrects it.
        XCTAssertEqual(completion("getu", in: "getUserName()\ngetu"), "getUserName")
    }

    func testExactCaseMatchWinsOverCaseInsensitiveOne() {
        // Both "Value" and "value" are present; a case-sensitive prefix wins.
        let text = "Value value\nval"
        XCTAssertEqual(completion("val", in: text), "value")
        XCTAssertEqual(completion("Val", in: text), "Value")
    }

    // MARK: - Ranking & guards

    func testMoreFrequentWordWins() {
        // "count" appears twice, "counter" once; the frequent one ranks first.
        let text = "count count counter\ncou"
        XCTAssertEqual(completion("cou", in: text), "count")
    }

    func testShorterCompletionWinsOnEqualFrequency() {
        XCTAssertEqual(completion("re", in: "rect renderer\nre"), "rect")
    }

    func testNeverCompletesToItselfOrShorter() {
        // Only the in-progress token exists; nothing longer to complete to.
        XCTAssertNil(completion("value", in: "value"))
    }

    func testRequiresAtLeastTwoCharacters() {
        XCTAssertNil(completion("u", in: "userName\nu"))
    }
}
