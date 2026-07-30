import XCTest

@testable import HedgeMemoCore

@MainActor
final class ImportHashIndexMemoryTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hedgememo-import-index-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLargeExactIndexStagesHashesOnDiskOneAtATime() throws {
        var index: FileBackedHashIndex? = try FileBackedHashIndex(
            existingHashes: (0..<10_000).lazy.map { "existing-\($0)" }
        )
        let storageURL = try XCTUnwrap(index?.storageURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertEqual(index?.storedHashCount, 10_000)
        XCTAssertEqual(index?.peakStoredHashCount, 10_000)
        XCTAssertEqual(index?.peakResidentHashCount, 1)
        XCTAssertEqual(index?.configuredCacheSizeKiB, 128)
        XCTAssertEqual(index?.configuredMmapSizeBytes, 0)
        XCTAssertFalse(try XCTUnwrap(index).insertIfNew("existing-5000"))
        XCTAssertTrue(try XCTUnwrap(index).insertIfNew("new"))
        try XCTUnwrap(index).setPosition(42, for: "new")
        XCTAssertEqual(try XCTUnwrap(index).position(for: "new"), 42)
        try XCTUnwrap(index).setPosition(73, for: "new")
        XCTAssertEqual(try XCTUnwrap(index).position(for: "new"), 73)
        try XCTUnwrap(index).remove("new")
        XCTAssertNil(try XCTUnwrap(index).position(for: "new"))
        XCTAssertTrue(try XCTUnwrap(index).insertIfNew("new"))

        index = nil
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storageURL.deletingLastPathComponent().path
            )
        )
    }

    func testTextStagingRetainsNoSwiftBodyAndRedirectReleasesItsFile() throws {
        var index: FileBackedHashIndex? = try FileBackedHashIndex(
            existingHashes: EmptyCollection<String>()
        )
        let storageURL = try XCTUnwrap(index?.storageURL)
        let id = UUID()
        let staged = "保留\u{0}内嵌空字符"
        try XCTUnwrap(index).stageText(staged, for: id)
        var provider: ClipboardEntryTextProvider? =
            try XCTUnwrap(index).makeTextProvider()

        XCTAssertEqual(provider?.text(for: id), staged)
        XCTAssertEqual(index?.stagedTextBodyCount, 1)
        XCTAssertEqual(index?.currentStagedTextBodyCount, 1)
        XCTAssertEqual(index?.peakResidentTextBodyCount, 1)

        let canonical = ClipboardEntryTextProvider { requestedID in
            requestedID == id ? staged : nil
        }
        provider?.redirect(to: canonical)
        index = nil

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storageURL.path),
            "redirecting durable bodies must release the disposable database"
        )
        XCTAssertEqual(provider?.text(for: id), staged)
        provider = nil
    }

    func testBinaryHashKeysPreserveZerosAndStayBoundedToCurrentKey() throws {
        let index = try FileBackedHashIndex(
            existingHashes: EmptyCollection<String>()
        )
        let first = Data([0, 0] + Array(repeating: 0, count: 32))
        let second = Data([1, 0] + Array(repeating: 0, count: 32))
        let legacy = Data([0, 1, 0, 255, 0, 42])

        XCTAssertTrue(try index.insertIfNew(first))
        XCTAssertFalse(try index.insertIfNew(first))
        XCTAssertTrue(try index.insertIfNew(second))
        XCTAssertTrue(try index.insertIfNew(legacy))
        try index.setPosition(12, for: first)
        try index.setPosition(13, for: second)
        XCTAssertEqual(try index.position(for: first), 12)
        XCTAssertEqual(try index.position(for: second), 13)
        try index.remove(first)
        XCTAssertNil(try index.position(for: first))
        XCTAssertEqual(try index.position(for: second), 13)
        XCTAssertEqual(index.peakResidentHashCount, 1)
        XCTAssertEqual(index.peakResidentKeyByteCount, 34)
    }

    func testMemeImportUsesFileIndexAndKeepsExactByteDeduplication() throws {
        let repository = MemeRepository(rootURL: tempRoot("store"))
        let store = MemeStore(repository: repository)
        XCTAssertTrue(
            store.addImageData(
                ImageAssetData(data: Fixture.gifBytes, fileExtension: "gif"),
                note: "已有"
            )
        )
        store.flushPendingSave()

        let source = tempRoot("sources")
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Fixture.gifBytes.write(
            to: source.appendingPathComponent("duplicate.gif")
        )
        let unique = try XCTUnwrap(Fixture.solidImage(0.72, size: 11).pngData)
        try unique.write(to: source.appendingPathComponent("unique.png"))
        let records = [
            MemeItem(
                fileName: "duplicate.gif",
                contentHash: "untrusted-duplicate",
                note: "不应导入"
            ),
            MemeItem(
                fileName: "unique.png",
                contentHash: "untrusted-unique",
                note: "新图"
            ),
        ]

        try store.importArchive(categories: [], imagesURL: source) { consume in
            for record in records { try consume(record) }
        }
        store.flushPendingSave()

        XCTAssertEqual(store.memes.map(\.note).sorted(), ["已有", "新图"])
        XCTAssertEqual(
            store.lastImportHashIndexMetrics,
            MemeStore.ImportHashIndexMetrics(
                seededHashCount: 1,
                candidateHashCount: 2,
                acceptedHashCount: 1,
                peakResidentHashCount: 1
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: repository.imagesURL.path
            ).count,
            2
        )
    }
}
