import XCTest

@testable import HedgeMemoCore

final class RepositoryMemoryBoundsTests: XCTestCase {
    private final class CallbackCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hedgememo-memory-bounds-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEverySQLiteConnectionUsesBoundedPageCache() throws {
        let root = tempRoot("sqlite-cache")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let connection = try SQLiteConnection(
            url: root.appendingPathComponent("cache.sqlite3")
        )

        XCTAssertEqual(connection.configuredCacheSizeKiB, 512)
    }

    func testClipboardIdlePurgeClosesReaderWithoutLosingDeferredText() throws {
        let root = tempRoot("clipboard-reader")
        let body = String(repeating: "延迟剪贴板正文", count: 2_000)
        try ClipboardHistoryRepository(rootURL: root).save(
            ClipboardHistorySnapshot(entries: [
                ClipboardEntry(
                    kind: .text,
                    text: body,
                    contentHash: "clipboard-reader"
                )
            ])
        )

        let repository = ClipboardHistoryRepository(rootURL: root)
        let snapshot = try repository.load()
        XCTAssertFalse(repository.hasTransientTextReaderConnection)
        XCTAssertEqual(snapshot.entries[0].text, body)
        XCTAssertTrue(repository.hasTransientTextReaderConnection)

        repository.releaseTransientMemory()
        XCTAssertFalse(repository.hasTransientTextReaderConnection)
        XCTAssertEqual(snapshot.entries[0].text, body)
        XCTAssertTrue(repository.hasTransientTextReaderConnection)
    }

    func testMemeIdlePurgeClosesReaderWithoutLosingDeferredText() throws {
        let root = tempRoot("meme-reader")
        let note = String(repeating: "延迟备注", count: 2_000)
        let ocr = String(repeating: "延迟OCR", count: 2_000)
        try MemeRepository(rootURL: root).save(
            MemeSnapshot(memes: [
                MemeItem(
                    fileName: "deferred.png",
                    contentHash: "meme-reader",
                    note: note,
                    ocrText: ocr
                )
            ])
        )

        let repository = MemeRepository(rootURL: root)
        let snapshot = try repository.load()
        XCTAssertFalse(repository.hasTransientTextReaderConnection)
        XCTAssertEqual(snapshot.memes[0].note, note)
        XCTAssertEqual(snapshot.memes[0].ocrText, ocr)
        XCTAssertTrue(repository.hasTransientTextReaderConnection)

        repository.releaseTransientMemory()
        XCTAssertFalse(repository.hasTransientTextReaderConnection)
        XCTAssertEqual(snapshot.memes[0].note, note)
        XCTAssertEqual(snapshot.memes[0].ocrText, ocr)
        XCTAssertTrue(repository.hasTransientTextReaderConnection)
    }

    func testClipboardBurstRetainsAtMostTwoFullSnapshotsAndPersistsLatest() throws {
        let root = tempRoot("clipboard-snapshot-slot")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let callbackCounter = CallbackCounter()

        for index in 0..<80 {
            repository.saveAsync(
                ClipboardHistorySnapshot(entries: [
                    ClipboardEntry(
                        kind: .text,
                        text: "generation-\(index)",
                        contentHash: "generation-\(index)"
                    )
                ])
            ) { _, _ in
                callbackCounter.increment()
            }
        }
        repository.flushSnapshotWrites()

        XCTAssertEqual(callbackCounter.count, 80)
        XCTAssertLessThanOrEqual(repository.peakRetainedFullSnapshotCount, 2)
        XCTAssertEqual(
            try ClipboardHistoryRepository(rootURL: root).load()
                .entries.first?.text,
            "generation-79"
        )
    }

    func testSnapshotMarkersPreserveOrderingWithClipboardRowDeltas() throws {
        let root = tempRoot("clipboard-snapshot-delta-order")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let id = UUID()
        let first = ClipboardEntry(
            id: id,
            kind: .text,
            text: "完整快照",
            contentHash: "snapshot"
        )
        let laterDelta = ClipboardEntry(
            id: id,
            kind: .text,
            text: "稍后的单行增量",
            contentHash: "delta"
        )

        repository.saveAsync(
            ClipboardHistorySnapshot(entries: [first])
        ) { _, _ in }
        repository.saveDeltaAsync(
            upserts: [laterDelta],
            settings: ClipboardHistorySettings()
        ) { _ in }
        repository.flushSnapshotWrites()

        XCTAssertEqual(
            try ClipboardHistoryRepository(rootURL: root).load()
                .entries.first?.text,
            "稍后的单行增量"
        )
    }

    func testMemeBurstRetainsAtMostTwoFullSnapshotsAndPersistsLatest() throws {
        let root = tempRoot("meme-snapshot-slot")
        let repository = MemeRepository(rootURL: root)
        let callbackCounter = CallbackCounter()

        for index in 0..<80 {
            repository.saveAsync(
                MemeSnapshot(memes: [
                    MemeItem(
                        fileName: "\(index).png",
                        contentHash: "generation-\(index)",
                        note: "generation-\(index)"
                    )
                ])
            ) { _, _ in
                callbackCounter.increment()
            }
        }
        repository.flushSnapshotWrites()

        XCTAssertEqual(callbackCounter.count, 80)
        XCTAssertLessThanOrEqual(repository.peakRetainedFullSnapshotCount, 2)
        XCTAssertEqual(
            try MemeRepository(rootURL: root).load().memes.first?.note,
            "generation-79"
        )
    }
}
