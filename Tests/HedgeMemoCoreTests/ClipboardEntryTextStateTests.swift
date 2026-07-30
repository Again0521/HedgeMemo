import Foundation
import XCTest
@testable import HedgeMemoCore

final class ClipboardEntryTextStateTests: XCTestCase {
    func testCompactTextStateReducesEveryClipboardEntryStride() {
        XCTAssertLessThanOrEqual(ClipboardEntry.textStateStorageStride, 8)
        XCTAssertLessThanOrEqual(ClipboardEntry.storageStride, 248)
        XCTAssertGreaterThanOrEqual(
            ClipboardEntry.legacyTextStorageStrideForTesting
                - ClipboardEntry.storageStride,
            16
        )

        let entryCount = 10_000
        XCTAssertGreaterThanOrEqual(
            entryCount * (
                ClipboardEntry.legacyTextStorageStrideForTesting
                    - ClipboardEntry.storageStride
            ),
            160_000
        )
    }

    func testResidentTextBoxesPreserveClipboardEntryValueSemantics() {
        let original = ClipboardEntry(
            kind: .text,
            text: "original text",
            contentHash: "resident"
        )
        var edited = original

        edited.text = "edited text"

        XCTAssertEqual(original.text, "original text")
        XCTAssertEqual(edited.text, "edited text")
        XCTAssertEqual(original.decodedStoredText, "original text")
        XCTAssertEqual(edited.decodedStoredText, "edited text")
    }

    func testDeferredCopyCanBecomeResidentWithoutChangingItsSource() {
        let id = UUID()
        let provider = ClipboardEntryTextProvider { requestedID in
            requestedID == id ? "let databaseValue = 42" : nil
        }
        var deferred = ClipboardEntry(
            id: id,
            kind: .text,
            text: "discarded resident value",
            contentHash: "deferred"
        )
        deferred.deferText(to: provider, automaticCategory: .code)
        var edited = deferred

        edited.text = "https://example.com"

        XCTAssertNil(deferred.decodedStoredText)
        XCTAssertEqual(deferred.text, "let databaseValue = 42")
        XCTAssertEqual(deferred.automaticContentCategory, .code)
        XCTAssertEqual(edited.decodedStoredText, "https://example.com")
        XCTAssertEqual(edited.automaticContentCategory, .link)
    }

    func testMetadataAndPersistenceProjectionsKeepExistingJSONSemantics() throws {
        let original = ClipboardEntry(
            kind: .text,
            text: "projection body",
            contentHash: "projection"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(original.metadataProjection)
            ) as? [String: Any]
        )
        XCTAssertNil(metadataObject["text"])
        XCTAssertEqual(original.text, "projection body")

        let persistence = original.persistenceProjection
        XCTAssertEqual(persistence.text, "projection body")
        XCTAssertEqual(
            persistence.entry.decodedStoredText,
            "projection body"
        )
        let decoded = try decoder.decode(
            ClipboardEntry.self,
            from: encoder.encode(persistence.entry)
        )
        XCTAssertEqual(decoded.text, "projection body")
        XCTAssertEqual(decoded.contentHash, original.contentHash)
    }

    func testNilImageNotesAndPasswordBodiesRemainLossless() {
        let image = ClipboardEntry(
            kind: .image,
            text: nil,
            contentHash: "image"
        )
        XCTAssertNil(image.text)
        XCTAssertNil(image.decodedStoredText)

        let id = UUID()
        let ciphertext = "encrypted-password-envelope"
        let provider = ClipboardEntryTextProvider { requestedID in
            requestedID == id ? ciphertext : nil
        }
        var password = ClipboardEntry(
            id: id,
            kind: .text,
            contentHash: "password",
            origin: .concealedPassword
        )
        password.deferText(to: provider, automaticCategory: .password)
        XCTAssertEqual(password.text, ciphertext)
        XCTAssertEqual(password.automaticContentCategory, .password)
        XCTAssertTrue(password.isSecret)
    }

    func testTenThousandDeferredEntriesRetainNoResidentBodies() {
        let provider = ClipboardEntryTextProvider { _ in "lazy body" }
        var entries: [ClipboardEntry] = []
        entries.reserveCapacity(10_000)
        for index in 0..<10_000 {
            var entry = ClipboardEntry(
                kind: .text,
                text: "resident-\(index)",
                contentHash: "text-state-\(index)"
            )
            entry.deferText(to: provider, automaticCategory: .text)
            entries.append(entry)
        }

        XCTAssertTrue(entries.allSatisfy { $0.decodedStoredText == nil })
        XCTAssertTrue(entries.allSatisfy {
            $0.automaticContentCategory == .text
        })
        XCTAssertEqual(entries[9_999].text, "lazy body")
    }
}
