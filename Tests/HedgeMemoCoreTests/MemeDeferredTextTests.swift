import XCTest

@testable import HedgeMemoCore

@MainActor
final class MemeDeferredTextTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-meme-deferred-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReloadKeepsNotesAndOCRDeferredWithoutChangingSearch() throws {
        let repository = MemeRepository(rootURL: tempRoot("large"))
        let memes = (0..<120).map { index in
            MemeItem(
                fileName: "\(index).gif",
                contentHash: "meme-large-\(index)",
                note: String(repeating: "备注\(index)-", count: 500),
                ocrText: String(repeating: "识别正文\(index)-", count: 1_500)
                    + (index == 119 ? "ocr-tail-needle" : ""),
                sortOrder: index,
                createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }
        try repository.save(MemeSnapshot(memes: memes))

        let loaded = try repository.load()
        XCTAssertEqual(loaded.memes.count, memes.count)
        XCTAssertTrue(loaded.memes.allSatisfy { $0.decodedStoredTextByteCount == 0 })
        XCTAssertEqual(loaded.memes[119].note, memes[119].note)
        XCTAssertEqual(loaded.memes[119].ocrText, memes[119].ocrText)

        repository.releaseTransientTextCache()
        XCTAssertEqual(loaded.memes[119].ocrText, memes[119].ocrText)

        let store = MemeStore(repository: repository)
        XCTAssertEqual(
            store.filteredMemes(query: "ocr-tail-needle").map(\.id),
            [memes[119].id]
        )
        XCTAssertTrue(store.memes.allSatisfy { $0.decodedStoredTextByteCount == 0 })
    }

    func testNewMemeDropsResidentNoteAndOCRAfterDeltaWrite() async {
        let repository = MemeRepository(rootURL: tempRoot("new"))
        let store = MemeStore(repository: repository)
        let note = String(repeating: "new-note-", count: 1_000)
        let ocr = String(repeating: "new-ocr-", count: 2_000)
        XCTAssertTrue(
            store.addImageData(
                ImageAssetData(data: Fixture.gifBytes, fileExtension: "gif"),
                note: note,
                ocrText: ocr
            )
        )
        store.flushPendingSave()

        for _ in 0..<20 where store.memes[0].decodedStoredTextByteCount != 0 {
            await Task.yield()
        }

        XCTAssertEqual(store.memes[0].decodedStoredTextByteCount, 0)
        XCTAssertEqual(store.memes[0].note, note)
        XCTAssertEqual(store.memes[0].ocrText, ocr)
    }

    func testDeferredMemeTextPreservesEmbeddedNullScalars() throws {
        let repository = MemeRepository(rootURL: tempRoot("null"))
        let note = "note\u{0}suffix"
        let ocr = "ocr\u{0}middle\u{0}suffix"
        try repository.save(
            MemeSnapshot(
                memes: [
                    MemeItem(
                        fileName: "null.gif",
                        contentHash: "null-meme",
                        note: note,
                        ocrText: ocr
                    )
                ]
            )
        )

        let loaded = try repository.load()
        XCTAssertEqual(loaded.memes[0].decodedStoredTextByteCount, 0)
        XCTAssertEqual(loaded.memes[0].note, note)
        XCTAssertEqual(loaded.memes[0].ocrText, ocr)
    }

    func testBulkSnapshotCompactsBodiesWithoutARevisionDictionary() async throws {
        let repository = MemeRepository(rootURL: tempRoot("bulk"))
        let store = MemeStore(repository: repository)
        let images = tempRoot("bulk-images")
        try FileManager.default.createDirectory(
            at: images,
            withIntermediateDirectories: true
        )
        let category = MemeCategory(name: "批量")
        var records: [MemeItem] = []
        for index in 0..<40 {
            let fileName = "\(index).png"
            let image = Fixture.solidImage(
                CGFloat(index + 1) / 41,
                size: CGFloat(10 + index % 3)
            )
            try XCTUnwrap(image.pngData).write(
                to: images.appendingPathComponent(fileName)
            )
            records.append(
                MemeItem(
                    fileName: fileName,
                    contentHash: "stale-\(index)",
                    note: "\(String(repeating: "批量备注", count: 200))-\(index)",
                    ocrText: "\(String(repeating: "批量 OCR", count: 300))-\(index)",
                    categoryID: category.id,
                    sortOrder: index
                )
            )
        }

        try store.importArchive(categories: [category], imagesURL: images) {
            consume in
            for record in records { try consume(record) }
        }
        store.flushPendingSave()
        for _ in 0..<20 where store.memes.contains(where: {
            $0.decodedStoredTextByteCount > 0
        }) {
            await Task.yield()
        }

        XCTAssertEqual(store.memes.count, 40)
        XCTAssertTrue(
            store.memes.allSatisfy { $0.decodedStoredTextByteCount == 0 }
        )
        XCTAssertEqual(store.memes.last?.ocrText, records.last?.ocrText)
    }
}
