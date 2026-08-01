import Foundation
import XCTest
@testable import HedgeMemoCore

final class ClipboardEntryTextStateTests: XCTestCase {
    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

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

    func testPersistenceProjectionLoadsColdTextOnceWithoutCachingIt() throws {
        let id = UUID()
        let counter = LoadCounter()
        let provider = ClipboardEntryTextProvider { requestedID in
            guard requestedID == id else { return nil }
            counter.increment()
            return "cold clipboard body"
        }
        var deferred = ClipboardEntry(
            id: id,
            kind: .text,
            contentHash: "cold-persistence"
        )
        deferred.deferText(to: provider, automaticCategory: .text)

        let persistence = deferred.persistenceProjection
        let decoded = try JSONDecoder().decode(
            ClipboardEntry.self,
            from: JSONEncoder().encode(persistence.entry)
        )

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(persistence.text, "cold clipboard body")
        XCTAssertEqual(decoded.text, "cold clipboard body")
        XCTAssertNil(deferred.decodedStoredText)

        XCTAssertEqual(deferred.text, "cold clipboard body")
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(deferred.text, "cold clipboard body")
        XCTAssertEqual(counter.count, 2)
    }

    func testPersistenceProjectionReusesWarmClipboardCache() {
        let id = UUID()
        let counter = LoadCounter()
        let provider = ClipboardEntryTextProvider { requestedID in
            guard requestedID == id else { return nil }
            counter.increment()
            return "warm clipboard body"
        }
        var deferred = ClipboardEntry(
            id: id,
            kind: .text,
            contentHash: "warm-persistence"
        )
        deferred.deferText(to: provider, automaticCategory: .text)

        XCTAssertEqual(deferred.text, "warm clipboard body")
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(
            deferred.persistenceProjection.text,
            "warm clipboard body"
        )
        XCTAssertEqual(counter.count, 1)
    }

    func testBulkClipboardPersistenceDoesNotPopulateDisplayCache() {
        let counter = LoadCounter()
        let provider = ClipboardEntryTextProvider { id in
            counter.increment()
            return "clipboard-\(id.uuidString)"
        }
        var entries = (0..<400).map { index in
            ClipboardEntry(
                kind: .text,
                contentHash: "bulk-clipboard-persistence-\(index)"
            )
        }
        for index in entries.indices {
            entries[index].deferText(
                to: provider,
                automaticCategory: .text
            )
        }

        for entry in entries {
            XCTAssertFalse(entry.persistenceProjection.text?.isEmpty ?? true)
        }
        XCTAssertEqual(counter.count, 400)

        for entry in entries {
            XCTAssertFalse(entry.text?.isEmpty ?? true)
        }
        XCTAssertEqual(counter.count, 800)
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
