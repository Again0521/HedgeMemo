import XCTest

@testable import HedgeMemoCore

final class ArchiveStreamingTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hedgememo-archive-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testManifestEncodingIsBoundedToOneRecordAndRemainsVersionTwoCompatible() throws {
        let category = MemeCategory(name: "流式分类")
        let body = String(repeating: "逐条编码正文", count: 2_000)
        let memes = (0..<120).map { index in
            MemeItem(
                fileName: "\(index).png",
                contentHash: "hash-\(index)",
                note: "\(body)-\(index)",
                ocrText: "\(body)-OCR-\(index)",
                categoryID: category.id,
                sortOrder: index
            )
        }
        let clipboardEntries = (0..<120).map { index in
            ClipboardEntry(
                kind: .text,
                text: "\(body)-剪贴板-\(index)",
                contentHash: "clipboard-\(index)"
            )
        }
        let manifest = MemeArchiveManifest(
            memeSnapshot: MemeSnapshot(categories: [category], memes: memes),
            clipboardSnapshot: ClipboardHistorySnapshot(entries: clipboardEntries)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-streaming-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let metrics = try MemeArchiveService.writeManifest(manifest, to: url)
        let size = try XCTUnwrap(
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        XCTAssertEqual(metrics.encodedRecordCount, 244)
        XCTAssertLessThan(metrics.largestEncodedRecordByteCount * 100, size)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoded = try decoder.decode(MemeArchiveManifest.self, from: mapped)
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertEqual(decoded.memeSnapshot?.memes.count, 120)
        XCTAssertEqual(decoded.memeSnapshot?.memes.last?.ocrText, "\(body)-OCR-119")
        XCTAssertEqual(decoded.clipboardSnapshot?.entries.last?.text, "\(body)-剪贴板-119")
    }

    func testVersionThreeKeepsCatalogSmallAndDecodesRecordsIncrementally() throws {
        let category = MemeCategory(name: "目录分类")
        let largeBody = String(repeating: "带换行正文\n", count: 2_000)
        let memes = (0..<80).map { index in
            MemeItem(
                fileName: "\(index).png",
                contentHash: "meme-\(index)",
                note: "\(largeBody)-\(index)",
                ocrText: "OCR-\(largeBody)-\(index)",
                categoryID: index.isMultiple(of: 2) ? category.id : nil,
                sortOrder: index
            )
        }
        let clipboardEntries = (0..<80).map { index in
            ClipboardEntry(
                kind: .text,
                text: "\(largeBody)-clipboard-\(index)",
                contentHash: "clipboard-\(index)"
            )
        }
        let memeRepository = MemeRepository(rootURL: tempRoot("source-memes"))
        let clipboardRepository = ClipboardHistoryRepository(
            rootURL: tempRoot("source-clipboard")
        )
        let destinationRoot = tempRoot("destination")
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let archiveURL = destinationRoot.appendingPathComponent("streaming.zip")

        try MemeArchiveService.export(
            memeSnapshot: MemeSnapshot(categories: [category], memes: memes),
            memeRepository: memeRepository,
            clipboardSnapshot: ClipboardHistorySnapshot(entries: clipboardEntries),
            clipboardRepository: clipboardRepository,
            destination: archiveURL
        )
        let extracted = try MemeArchiveService.extract(from: archiveURL)
        defer { MemeArchiveService.removeExtraction(extracted.directory) }

        XCTAssertEqual(extracted.manifest.formatVersion, 3)
        XCTAssertNil(extracted.manifest.memeSnapshot)
        XCTAssertNil(extracted.manifest.clipboardSnapshot)
        XCTAssertEqual(extracted.manifest.availableMemeCategories.map(\.name), ["目录分类"])
        XCTAssertTrue(extracted.manifest.hasUncategorizedMemes)
        XCTAssertEqual(extracted.manifest.memeRecordCount, 80)
        XCTAssertEqual(extracted.manifest.clipboardRecordCount, 80)
        XCTAssertTrue(
            extracted.manifest.availableClipboardCategoryKeys.contains(.builtin(.text))
        )

        let manifestSize = try XCTUnwrap(
            try extracted.directory
                .appendingPathComponent("manifest.json")
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize
        )
        XCTAssertLessThan(manifestSize, 100_000)

        var lastMeme: MemeItem?
        XCTAssertEqual(
            try MemeArchiveService.forEachMeme(in: extracted) { lastMeme = $0 },
            80
        )
        XCTAssertEqual(lastMeme?.ocrText, "OCR-\(largeBody)-79")

        var lastClipboardEntry: ClipboardEntry?
        XCTAssertEqual(
            try MemeArchiveService.forEachClipboardEntry(in: extracted) {
                lastClipboardEntry = $0
            },
            80
        )
        XCTAssertEqual(lastClipboardEntry?.text, "\(largeBody)-clipboard-79")
    }

    func testVersionTwoRecordIterationRemainsCompatible() throws {
        let memes = [
            MemeItem(fileName: "legacy.png", contentHash: "legacy", note: "旧备注")
        ]
        let entries = [
            ClipboardEntry(kind: .text, text: "旧剪贴板", contentHash: "legacy")
        ]
        let manifest = MemeArchiveManifest(
            memeSnapshot: MemeSnapshot(memes: memes),
            clipboardSnapshot: ClipboardHistorySnapshot(entries: entries)
        )
        let archive = ExtractedMemeArchive(
            manifest: manifest,
            directory: tempRoot("legacy")
        )

        var importedMemes: [MemeItem] = []
        var importedEntries: [ClipboardEntry] = []
        XCTAssertEqual(
            try MemeArchiveService.forEachMeme(in: archive) {
                importedMemes.append($0)
            },
            1
        )
        XCTAssertEqual(
            try MemeArchiveService.forEachClipboardEntry(in: archive) {
                importedEntries.append($0)
            },
            1
        )
        XCTAssertEqual(importedMemes.first?.note, "旧备注")
        XCTAssertEqual(importedEntries.first?.text, "旧剪贴板")
    }

    func testTruncatedVersionThreeRecordsFailValidationBeforeImport() throws {
        let twoMemes = [
            MemeItem(fileName: "one.png", contentHash: "one"),
            MemeItem(fileName: "two.png", contentHash: "two"),
        ]
        let manifest = MemeArchiveManifest(
            streamingMemeSnapshot: MemeSnapshot(memes: twoMemes),
            clipboardSnapshot: nil
        )
        let directory = tempRoot("truncated")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var oneRecord = try encoder.encode(twoMemes[0])
        oneRecord.append(0x0A)
        try oneRecord.write(
            to: directory.appendingPathComponent("meme-items.jsonl")
        )

        XCTAssertThrowsError(
            try MemeArchiveService.validateRecordFiles(
                manifest: manifest,
                in: directory
            )
        )
    }
}
