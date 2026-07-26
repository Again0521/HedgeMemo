import AppKit
import XCTest

@testable import HedgeMemoCore

@MainActor
final class ClipboardPasteQueueTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-queue-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testQueueIsFIFODeDuplicatedAndPersists() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("fifo"))
        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(store.addText("first"))
        XCTAssertTrue(store.addText("second"))
        let first = try XCTUnwrap(store.entries.first(where: { $0.text == "first" }))
        let second = try XCTUnwrap(store.entries.first(where: { $0.text == "second" }))

        XCTAssertEqual(try store.enqueueForPaste(id: first.id), 1)
        XCTAssertEqual(try store.enqueueForPaste(id: second.id), 2)
        XCTAssertEqual(try store.enqueueForPaste(id: first.id), 1)
        XCTAssertEqual(store.pasteQueueCount, 2)
        XCTAssertEqual(store.pasteQueuePosition(of: second.id), 2)

        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.settings.resolvedPasteQueueEntryIDs, [first.id, second.id])
    }

    func testPasteNextWritesThenRemovesOnlySuccessfulHead() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("consume"))
        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(store.addText("first"))
        XCTAssertTrue(store.addText("second"))
        let first = try XCTUnwrap(store.entries.first(where: { $0.text == "first" }))
        let second = try XCTUnwrap(store.entries.first(where: { $0.text == "second" }))
        _ = try store.enqueueForPaste(id: first.id)
        _ = try store.enqueueForPaste(id: second.id)

        let pasteboard = NSPasteboard.withUniqueName()
        let pasted = try store.pasteNextQueued(to: pasteboard)
        XCTAssertEqual(pasted.id, first.id)
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
        XCTAssertEqual(store.settings.resolvedPasteQueueEntryIDs, [second.id])
        XCTAssertEqual(store.entries.first(where: { $0.id == first.id })?.useCount, 1)

        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.settings.resolvedPasteQueueEntryIDs, [second.id])
    }

    func testQueuedRichTextKeepsOriginalRepresentations() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("rich"))
        let store = ClipboardHistoryStore(repository: repository)
        let rtf = Data(#"{\rtf1\ansi queued}"#.utf8)
        XCTAssertTrue(
            try store.addRichText(
                ClipboardRichTextPayload(
                    plainText: "queued",
                    formats: [
                        ClipboardFormatData(
                            typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                            data: rtf
                        )
                    ]
                ),
                source: nil
            )
        )
        let entry = try XCTUnwrap(store.entries.first)
        _ = try store.enqueueForPaste(id: entry.id)

        let pasteboard = NSPasteboard.withUniqueName()
        _ = try store.pasteNextQueued(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "queued")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
    }

    func testLockedSecretStaysAtQueueHeadAndSurfacesError() throws {
        let secret = ClipboardEntry(
            kind: .text,
            text: "ciphertext",
            contentHash: "secret",
            origin: .concealedPassword
        )
        var settings = ClipboardHistorySettings()
        settings.pasteQueueEntryIDs = [secret.id]
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("secret"))
        try repository.save(ClipboardHistorySnapshot(entries: [secret], settings: settings))
        let store = ClipboardHistoryStore(repository: repository)

        XCTAssertThrowsError(
            try store.pasteNextQueued(
                to: NSPasteboard.withUniqueName(),
                allowsProtectedEntries: false
            )
        ) {
            XCTAssertEqual($0 as? ClipboardPasteQueueError, .protectedEntryLocked)
        }
        XCTAssertEqual(store.settings.resolvedPasteQueueEntryIDs, [secret.id])
        XCTAssertEqual(store.lastError, ClipboardPasteQueueError.protectedEntryLocked.localizedDescription)
    }

    func testDeleteClearAndExportRemoveStaleQueueReferences() throws {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(rootURL: tempRoot("cleanup"))
        )
        XCTAssertTrue(store.addText("ordinary"))
        let ordinary = try XCTUnwrap(store.entries.first)
        _ = try store.enqueueForPaste(id: ordinary.id)
        store.delete(id: ordinary.id)
        XCTAssertEqual(store.pasteQueueCount, 0)
        XCTAssertTrue(store.settings.resolvedPasteQueueEntryIDs.isEmpty)

        let secret = ClipboardEntry(
            kind: .text,
            text: "ciphertext",
            contentHash: "secret",
            origin: .concealedPassword
        )
        var settings = ClipboardHistorySettings()
        settings.pasteQueueEntryIDs = [secret.id]
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("export"))
        try repository.save(ClipboardHistorySnapshot(entries: [secret], settings: settings))
        let secretStore = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(secretStore.snapshot().settings.resolvedPasteQueueEntryIDs.isEmpty)
        secretStore.clearHistory()
        XCTAssertTrue(secretStore.settings.resolvedPasteQueueEntryIDs.isEmpty)
    }

    func testQueueFailuresThrowAndKeepTheirState() {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(rootURL: tempRoot("errors"))
        )
        XCTAssertThrowsError(try store.enqueueForPaste(id: UUID())) {
            XCTAssertEqual($0 as? ClipboardPasteQueueError, .entryNotFound)
        }
        XCTAssertThrowsError(try store.pasteNextQueued(to: NSPasteboard.withUniqueName())) {
            XCTAssertEqual($0 as? ClipboardPasteQueueError, .queueEmpty)
        }
        XCTAssertEqual(store.pasteQueueCount, 0)
    }

    func testLegacyDuplicateCollapseKeepsOneQueuePositionForMergedEntry() throws {
        let id1 = UUID()
        let id2 = UUID()
        let old = ClipboardEntry(
            id: id1,
            kind: .text,
            text: "duplicate",
            contentHash: "same",
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let new = ClipboardEntry(
            id: id2,
            kind: .text,
            text: "duplicate",
            contentHash: "same",
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        var settings = ClipboardHistorySettings()
        settings.pasteQueueEntryIDs = [id1, id2]
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("dedup"))
        try repository.save(ClipboardHistorySnapshot(entries: [old, new], settings: settings))

        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(store.entries.map(\.id), [id2])
        XCTAssertEqual(store.settings.resolvedPasteQueueEntryIDs, [id2])
        XCTAssertEqual(store.pasteQueueCount, 1)
    }
}
