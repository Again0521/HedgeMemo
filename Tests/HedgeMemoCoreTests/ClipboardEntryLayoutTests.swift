import Foundation
import XCTest
@testable import HedgeMemoCore

final class ClipboardEntryLayoutTests: XCTestCase {
    func testClassificationBitfieldReducesEveryClipboardEntryStride() {
        XCTAssertLessThanOrEqual(ClipboardEntry.storageStride, 264)
        XCTAssertGreaterThanOrEqual(
            ClipboardEntry.legacyStorageStrideForTesting
                - ClipboardEntry.storageStride,
            8,
            "the packed state must cross an alignment boundary, not only fill padding"
        )

        let entryCount = 10_000
        XCTAssertGreaterThanOrEqual(
            entryCount * (
                ClipboardEntry.legacyStorageStrideForTesting
                    - ClipboardEntry.storageStride
            ),
            80_000,
            "the configured maximum history must save measurable resident model bytes"
        )
    }

    func testAllClassificationStatesKeepTheirExistingCodableRepresentation() throws {
        let fixtures: [(ClipboardEntry, String, String?)] = [
            (
                ClipboardEntry(
                    kind: .text,
                    text: "ordinary prose",
                    contentHash: "text"
                ),
                "text",
                nil
            ),
            (
                ClipboardEntry(
                    kind: .text,
                    text: "let answer = 42",
                    contentHash: "code"
                ),
                "code",
                nil
            ),
            (
                ClipboardEntry(
                    kind: .text,
                    text: "https://example.com",
                    contentHash: "link"
                ),
                "link",
                nil
            ),
            (
                ClipboardEntry(
                    kind: .image,
                    contentHash: "image"
                ),
                "image",
                nil
            ),
            (
                ClipboardEntry(
                    kind: .image,
                    contentHash: "screenshot",
                    origin: .hedgeMemoScreenshot
                ),
                "screenshot",
                "memeMemoScreenshot"
            ),
            (
                ClipboardEntry(
                    kind: .text,
                    contentHash: "password",
                    origin: .concealedPassword
                ),
                "password",
                "concealedPassword"
            ),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for (entry, automaticCategory, origin) in fixtures {
            let data = try encoder.encode(entry)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(
                object["kind"] as? String,
                entry.kind.rawValue
            )
            XCTAssertEqual(
                object["automaticContentCategoryStorageValue"] as? String,
                automaticCategory
            )
            XCTAssertEqual(object["origin"] as? String, origin)

            let decoded = try decoder.decode(ClipboardEntry.self, from: data)
            XCTAssertEqual(decoded.kind, entry.kind)
            XCTAssertEqual(decoded.origin, entry.origin)
            XCTAssertEqual(
                decoded.automaticContentCategory.rawValue,
                automaticCategory
            )
        }
    }

    func testMissingAndUnknownCachedCategoryStillFallBackToExactClassification() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let entry = ClipboardEntry(
            kind: .text,
            text: "let answer = 42",
            contentHash: "fallback"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(entry)
            ) as? [String: Any]
        )

        object.removeValue(
            forKey: "automaticContentCategoryStorageValue"
        )
        let missing = try decoder.decode(
            ClipboardEntry.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(missing.automaticContentCategory, .code)

        object["automaticContentCategoryStorageValue"] = "future-category"
        let unknown = try decoder.decode(
            ClipboardEntry.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(unknown.automaticContentCategory, .code)
    }

    func testPublicKindOriginAndTextMutationRemainIndependent() {
        var entry = ClipboardEntry(
            kind: .text,
            text: "ordinary",
            contentHash: "mutations"
        )

        entry.kind = .image
        entry.origin = .hedgeMemoScreenshot
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.origin, .hedgeMemoScreenshot)

        entry.text = "https://example.com"
        XCTAssertEqual(entry.automaticContentCategory, .screenshot)
        entry.origin = nil
        XCTAssertEqual(entry.automaticContentCategory, .image)
        entry.kind = .text
        XCTAssertEqual(entry.automaticContentCategory, .link)
    }
}
