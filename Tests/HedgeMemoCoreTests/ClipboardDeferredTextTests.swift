import XCTest

@testable import HedgeMemoCore

@MainActor
final class ClipboardDeferredTextTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-deferred-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReloadKeepsEveryBodyDeferredWhileExactSearchAndCopyDataStayLossless() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("large"))
        let entries = (0..<120).map { index in
            let suffix = index == 119 ? "-needle-at-the-end" : ""
            return ClipboardEntry(
                kind: .text,
                text: String(repeating: "正文\(index)-", count: 2_000) + suffix,
                contentHash: "large-\(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }
        try repository.save(ClipboardHistorySnapshot(entries: entries))

        let loaded = try repository.load()

        XCTAssertEqual(loaded.entries.count, entries.count)
        XCTAssertTrue(
            loaded.entries.allSatisfy { $0.decodedStoredText == nil },
            "the resident model must contain metadata references, not duplicated text bodies"
        )
        XCTAssertEqual(loaded.entries[119].text, entries[119].text)

        repository.releaseTransientTextCache()
        XCTAssertEqual(
            loaded.entries[119].text,
            entries[119].text,
            "evicting the bounded body cache must reload the exact persisted text"
        )

        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(
            store.orderedEntries(query: "needle-at-the-end").map(\.id),
            [entries[119].id],
            "deferred bodies must preserve exact search semantics beyond visible previews"
        )
        XCTAssertTrue(store.entries.allSatisfy { $0.decodedStoredText == nil })
    }

    func testLegacyPayloadIsBackfilledOnceThenLoadsFromCompactHeaders() throws {
        let root = tempRoot("legacy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("clipboard-history.json")
        let text = String(repeating: "legacy-body-", count: 4_000)
        let snapshot = ClipboardHistorySnapshot(
            entries: [
                ClipboardEntry(
                    kind: .text,
                    text: text,
                    contentHash: "legacy-deferred"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: legacyURL)

        let repository = ClipboardHistoryRepository(rootURL: root)
        let migrated = try repository.load()
        XCTAssertNil(migrated.entries[0].decodedStoredText)
        XCTAssertEqual(migrated.entries[0].text, text)

        repository.releaseTransientTextCache()
        let reloaded = try repository.load()
        XCTAssertNil(reloaded.entries[0].decodedStoredText)
        XCTAssertEqual(reloaded.entries[0].text, text)
        XCTAssertEqual(reloaded.entries[0].contentCategory, .text)
    }

    func testDeferredTextPreservesEmbeddedNullScalars() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("embedded-null"))
        let text = "prefix\u{0}middle\u{0}suffix"
        try repository.save(
            ClipboardHistorySnapshot(
                entries: [
                    ClipboardEntry(
                        kind: .text,
                        text: text,
                        contentHash: "embedded-null"
                    )
                ]
            )
        )

        let loaded = try repository.load()
        XCTAssertNil(loaded.entries[0].decodedStoredText)
        XCTAssertEqual(loaded.entries[0].text, text)
    }

    func testNewCaptureDropsItsResidentBodyAfterTheDeltaIsDurable() async throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("new-capture"))
        let store = ClipboardHistoryStore(repository: repository)
        let text = String(repeating: "new-capture-body-", count: 5_000)
        XCTAssertTrue(store.addText(text))
        store.flushPendingSave()

        for _ in 0..<20 where store.entries[0].decodedStoredText != nil {
            await Task.yield()
        }

        XCTAssertNil(
            store.entries[0].decodedStoredText,
            "new captures must not wait for an app restart before releasing their body"
        )
        XCTAssertEqual(store.entries[0].text, text)
    }

    func testBulkSnapshotCompactsBodiesWithoutARevisionDictionary() async throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("bulk"))
        let store = ClipboardHistoryStore(repository: repository)
        let assets = tempRoot("bulk-assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        let entries = (0..<100).map { index in
            ClipboardEntry(
                kind: .text,
                text: "\(String(repeating: "批量正文", count: 200))-\(index)",
                contentHash: "bulk-\(index)"
            )
        }

        try store.importArchive(
            ClipboardHistorySnapshot(entries: entries),
            imagesURL: assets,
            originalFormatsURL: assets
        )
        store.flushPendingSave()
        for _ in 0..<20 where store.entries.contains(where: {
            $0.decodedStoredText != nil
        }) {
            await Task.yield()
        }

        XCTAssertEqual(store.entries.count, 100)
        XCTAssertTrue(store.entries.allSatisfy { $0.decodedStoredText == nil })
        XCTAssertEqual(store.entries.last?.text, entries.last?.text)
    }

    func testOrderedCompactionSkipsANewerRevisionAtTheSamePosition() {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(rootURL: tempRoot("revision"))
        )
        let firstID = UUID()
        let secondID = UUID()
        let persistedFirst = ClipboardEntry(
            id: firstID,
            kind: .text,
            text: "旧版本",
            contentHash: "old",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let persistedSecond = ClipboardEntry(
            id: secondID,
            kind: .text,
            text: "可压缩",
            contentHash: "same",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let newerFirst = ClipboardEntry(
            id: firstID,
            kind: .text,
            text: "用户刚刚修改的新版本",
            contentHash: "new",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        store.injectPreviewEntries([newerFirst, persistedSecond])

        store.deferPersistedBodiesInOrder(
            matching: [persistedFirst, persistedSecond]
        )

        XCTAssertEqual(
            store.entries[0].decodedStoredText,
            "用户刚刚修改的新版本",
            "an older completed snapshot must never defer a newer edit"
        )
        XCTAssertNil(store.entries[1].decodedStoredText)
    }
}
