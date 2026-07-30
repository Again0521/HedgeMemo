import XCTest

@testable import HedgeMemoCore

final class PersistenceStateMemoryTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hedgememo-stateless-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLargeDeferredClipboardSnapshotDiffsInsideSQLiteWithoutRewrites() throws {
        let root = tempRoot("clipboard")
        let entries = (0..<600).map { index in
            ClipboardEntry(
                kind: .text,
                text: "\(String(repeating: "正文", count: 300))-\(index)",
                contentHash: "clipboard-\(index)"
            )
        }
        try ClipboardHistoryRepository(rootURL: root).save(
            ClipboardHistorySnapshot(entries: entries)
        )

        let repository = ClipboardHistoryRepository(rootURL: root)
        var loaded = try repository.load()
        XCTAssertTrue(loaded.entries.allSatisfy { $0.decodedStoredText == nil })

        try repository.save(loaded)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)

        loaded.entries[300].isPinned = true
        try repository.save(loaded)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)
    }

    func testLargeDeferredMemeSnapshotDiffsInsideSQLiteWithoutRewrites() throws {
        let root = tempRoot("memes")
        let category = MemeCategory(name: "巨量")
        let memes = (0..<600).map { index in
            MemeItem(
                fileName: "\(index).png",
                contentHash: "meme-\(index)",
                note: "\(String(repeating: "备注", count: 300))-\(index)",
                ocrText: "\(String(repeating: "OCR", count: 300))-\(index)",
                categoryID: category.id,
                sortOrder: index
            )
        }
        try MemeRepository(rootURL: root).save(
            MemeSnapshot(categories: [category], memes: memes)
        )

        let repository = MemeRepository(rootURL: root)
        var loaded = try repository.load()
        XCTAssertTrue(
            loaded.memes.allSatisfy { $0.decodedStoredTextByteCount == 0 }
        )

        try repository.save(loaded)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 0)

        loaded.memes[300].note = "只改变一条"
        try repository.save(loaded)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 1)
    }
}
