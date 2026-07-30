import AppKit
import XCTest

@testable import HedgeMemoCore

@MainActor
final class ClipboardArchiveBatchMemoryTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hedgememo-clipboard-batch-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fileNames(at url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    func testThousandRecordStreamPublishesAndPersistsOneExactBatch() async throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("large"))
        try repository.save(
            ClipboardHistorySnapshot(
                settings: ClipboardHistorySettings(maxEntries: 10_000)
            )
        )
        let store = ClipboardHistoryStore(repository: repository)
        let assets = tempRoot("large-assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        let revisionBefore = store.entriesRevision
        let writesBefore = repository.completedSnapshotWriteCount
        let bodySuffix = String(repeating: "正文数据", count: 2_048)

        try store.importArchive(
            imagesURL: assets,
            originalFormatsURL: assets
        ) { consume in
            for index in 0..<1_000 {
                try consume(
                    ClipboardEntry(
                        kind: .text,
                        text: "批量正文-\(index)-\(bodySuffix)",
                        contentHash: "untrusted-\(index)"
                    )
                )
            }
        }
        store.flushPendingSave()
        let stagingURL = try XCTUnwrap(store.lastArchiveImportStagingURL)
        for _ in 0..<40
        where FileManager.default.fileExists(atPath: stagingURL.path) {
            await Task.yield()
        }

        XCTAssertEqual(store.entries.count, 1_000)
        XCTAssertTrue(
            store.entries.allSatisfy { $0.decodedStoredText == nil },
            "accepted bodies must leave the observable Swift models immediately"
        )
        XCTAssertEqual(store.entriesRevision - revisionBefore, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingURL.path),
            "a durable snapshot must redirect providers and delete staging"
        )
        XCTAssertEqual(
            repository.completedSnapshotWriteCount - writesBefore,
            1
        )
        XCTAssertEqual(
            store.lastArchiveImportMetrics,
            ClipboardHistoryStore.ArchiveImportMetrics(
                seededHashCount: 0,
                candidateHashCount: 1_000,
                appliedRecordCount: 1_000,
                peakResidentHashCount: 1,
                peakResidentHashKeyByteCount: 34,
                hashIndexCacheSizeKiB: 128,
                hashIndexMmapSizeBytes: 0,
                peakIndexedHashCount: 1_000,
                entriesPublicationCount: 1,
                stagedTextBodyCount: 1_000,
                peakResidentTextBodyCount: 1,
                peakLiveMetadataCount: 1_000,
                peakSlotCount: 1_000,
                peakTrimHeapNodeCount: 1_000
            )
        )
        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.count, 1_000)
        XCTAssertTrue(reloaded.entries.first?.text?.hasPrefix("批量正文-0-") == true)
        XCTAssertTrue(reloaded.entries.last?.text?.hasPrefix("批量正文-999-") == true)
    }

    func testTwentyThousandRecordsKeepMetadataBoundedToCapacityPlusOne()
        async throws {
        let repository = ClipboardHistoryRepository(
            rootURL: tempRoot("bounded-metadata")
        )
        try repository.save(
            ClipboardHistorySnapshot(
                settings: ClipboardHistorySettings(maxEntries: 100)
            )
        )
        let store = ClipboardHistoryStore(repository: repository)
        let assets = tempRoot("bounded-metadata-assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        let revisionBefore = store.entriesRevision
        let writesBefore = repository.completedSnapshotWriteCount

        try store.importArchive(
            imagesURL: assets,
            originalFormatsURL: assets
        ) { consume in
            for index in 0..<20_000 {
                try consume(
                    ClipboardEntry(
                        kind: .text,
                        text: "有界记录-\(index)",
                        contentHash: "untrusted-\(index)"
                    )
                )
            }
            // The first copy has already fallen outside the 100-entry window.
            // It must be accepted again exactly like sequential ordinary
            // captures, proving the evicted hash and slot were both recycled.
            try consume(
                ClipboardEntry(
                    kind: .text,
                    text: "有界记录-0",
                    contentHash: "untrusted-repeat"
                )
            )
        }
        store.flushPendingSave()
        let stagingURL = try XCTUnwrap(store.lastArchiveImportStagingURL)
        for _ in 0..<40
        where FileManager.default.fileExists(atPath: stagingURL.path) {
            await Task.yield()
        }

        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.first?.text, "有界记录-19901")
        XCTAssertEqual(store.entries.last?.text, "有界记录-0")
        XCTAssertTrue(store.entries.allSatisfy {
            $0.decodedStoredText == nil
        })
        XCTAssertEqual(store.entriesRevision - revisionBefore, 1)
        XCTAssertEqual(
            repository.completedSnapshotWriteCount - writesBefore,
            1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingURL.path)
        )

        let metrics = store.lastArchiveImportMetrics
        XCTAssertEqual(metrics.candidateHashCount, 20_001)
        XCTAssertEqual(metrics.appliedRecordCount, 20_001)
        XCTAssertEqual(metrics.stagedTextBodyCount, 20_001)
        XCTAssertEqual(metrics.peakResidentHashCount, 1)
        XCTAssertEqual(metrics.hashIndexCacheSizeKiB, 128)
        XCTAssertEqual(metrics.hashIndexMmapSizeBytes, 0)
        XCTAssertEqual(metrics.peakIndexedHashCount, 101)
        XCTAssertEqual(metrics.peakResidentTextBodyCount, 1)
        XCTAssertEqual(metrics.peakLiveMetadataCount, 101)
        XCTAssertEqual(metrics.peakSlotCount, 101)
        XCTAssertLessThanOrEqual(metrics.peakTrimHeapNodeCount, 101)
        XCTAssertEqual(metrics.entriesPublicationCount, 1)

        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.count, 100)
        XCTAssertEqual(reloaded.entries.first?.text, "有界记录-19901")
        XCTAssertEqual(reloaded.entries.last?.text, "有界记录-0")
    }

    func testBoundedImportNeverEvictsEitherPinMode() throws {
        let quickPinned = ClipboardEntry(
            kind: .text,
            text: "快捷固定",
            contentHash: Data("快捷固定".utf8).clipboardContentHash,
            isPinned: true,
            pinnedOrder: 0
        )
        let desktopPinned = ClipboardEntry(
            kind: .text,
            text: "桌面固定",
            contentHash: Data("桌面固定".utf8).clipboardContentHash,
            isDesktopPinned: true,
            desktopPinnedOrder: 0
        )
        let ordinary = (0..<98).map { index in
            ClipboardEntry(
                kind: .text,
                text: "原有-\(index)",
                contentHash: "existing-\(index)"
            )
        }
        let repository = ClipboardHistoryRepository(
            rootURL: tempRoot("bounded-pins")
        )
        try repository.save(
            ClipboardHistorySnapshot(
                entries: [quickPinned, desktopPinned] + ordinary,
                settings: ClipboardHistorySettings(maxEntries: 100)
            )
        )
        let store = ClipboardHistoryStore(repository: repository)
        let assets = tempRoot("bounded-pins-assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )

        try store.importArchive(
            imagesURL: assets,
            originalFormatsURL: assets
        ) { consume in
            for index in 0..<1_000 {
                try consume(
                    ClipboardEntry(
                        kind: .text,
                        text: "新增-\(index)",
                        contentHash: "untrusted-\(index)"
                    )
                )
            }
            try consume(
                ClipboardEntry(
                    kind: .text,
                    text: "快捷固定",
                    contentHash: "untrusted-pinned-copy"
                )
            )
        }
        store.flushPendingSave()

        XCTAssertEqual(store.entries.count, 100)
        XCTAssertTrue(store.entries.contains {
            $0.id == quickPinned.id && $0.isPinned
        })
        XCTAssertTrue(store.entries.contains {
            $0.id == desktopPinned.id && $0.isDesktopPinned == true
        })
        XCTAssertEqual(
            store.entries.filter {
                !$0.isPinned && $0.isDesktopPinned != true
            }.count,
            98
        )
        XCTAssertEqual(
            store.lastArchiveImportMetrics.peakLiveMetadataCount,
            101
        )
        XCTAssertEqual(store.lastArchiveImportMetrics.peakSlotCount, 101)
    }

    func testTruncatedStreamRollsBackEveryCreatedSidecarBeforePublishing() throws {
        enum ImportFailure: Error { case truncated }

        let repository = ClipboardHistoryRepository(
            rootURL: tempRoot("rollback")
        )
        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(store.addText("原有内容"))
        store.flushPendingSave()
        let entriesBefore = store.entries
        let revisionBefore = store.entriesRevision
        let imagesBefore = try fileNames(at: repository.imagesURL)
        let formatsBefore = try fileNames(at: repository.originalFormatsURL)

        let assets = tempRoot("rollback-assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        try Fixture.gifBytes.write(
            to: assets.appendingPathComponent("new.gif")
        )
        let rtf = Data(#"{\rtf1\ansi rollback}"#.utf8)
        try rtf.write(to: assets.appendingPathComponent("new.rtf"))
        let rich = ClipboardEntry(
            kind: .text,
            text: "富文本",
            contentHash: "untrusted-rich",
            originalFormats: [
                ClipboardOriginalFormat(
                    typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                    fileName: "new.rtf",
                    byteCount: rtf.count
                )
            ]
        )
        let image = ClipboardEntry(
            kind: .image,
            imageFileName: "new.gif",
            contentHash: "untrusted-image"
        )

        XCTAssertThrowsError(
            try store.importArchive(
                imagesURL: assets,
                originalFormatsURL: assets
            ) { consume in
                try consume(rich)
                try consume(image)
                throw ImportFailure.truncated
            }
        )

        XCTAssertEqual(store.entries, entriesBefore)
        XCTAssertEqual(store.entriesRevision, revisionBefore)
        XCTAssertEqual(try fileNames(at: repository.imagesURL), imagesBefore)
        XCTAssertEqual(
            try fileNames(at: repository.originalFormatsURL),
            formatsBefore
        )
        XCTAssertEqual(
            store.lastArchiveImportMetrics.entriesPublicationCount,
            0
        )
        let stagingURL = try XCTUnwrap(store.lastArchiveImportStagingURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }
}
