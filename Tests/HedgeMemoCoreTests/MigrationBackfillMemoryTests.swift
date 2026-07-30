import XCTest

@testable import HedgeMemoCore

final class MigrationBackfillMemoryTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hedgememo-backfill-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLargeClipboardMigrationStagesOnlyOneSwiftRowAtATime() throws {
        let root = tempRoot("clipboard")
        let body = String(repeating: "迁移正文", count: 500)
        let entries = (0..<500).map { index in
            ClipboardEntry(
                kind: .text,
                text: "\(body)-\(index)",
                contentHash: "clipboard-\(index)"
            )
        }
        let seed = ClipboardHistoryRepository(rootURL: root)
        try seed.save(ClipboardHistorySnapshot(entries: entries))
        let connection = try SQLiteConnection(url: seed.databaseURL)
        try connection.execute(
            """
            UPDATE clipboard_entries
            SET header_payload = NULL,
                text_body = NULL,
                content_category = NULL
            """
        )

        let repository = ClipboardHistoryRepository(rootURL: root)
        let migrated = try repository.load()
        XCTAssertEqual(repository.lastDatabaseBackfillMetrics.rowCount, 500)
        XCTAssertEqual(
            repository.lastDatabaseBackfillMetrics.peakResidentRowCount,
            1
        )
        XCTAssertTrue(
            migrated.entries.allSatisfy { $0.decodedStoredText == nil }
        )
        XCTAssertEqual(migrated.entries.last?.text, "\(body)-499")

        let second = ClipboardHistoryRepository(rootURL: root)
        _ = try second.load()
        XCTAssertEqual(second.lastDatabaseBackfillMetrics.rowCount, 0)
        XCTAssertEqual(second.lastDatabaseBackfillMetrics.peakResidentRowCount, 0)
    }

    func testLargeMemeMigrationStagesOnlyOneSwiftRowAtATime() throws {
        let root = tempRoot("memes")
        let body = String(repeating: "迁移备注", count: 500)
        let memes = (0..<500).map { index in
            MemeItem(
                fileName: "\(index).png",
                contentHash: "meme-\(index)",
                note: "\(body)-\(index)",
                ocrText: "OCR-\(body)-\(index)",
                sortOrder: index
            )
        }
        let seed = MemeRepository(rootURL: root)
        try seed.save(MemeSnapshot(memes: memes))
        let connection = try SQLiteConnection(url: seed.databaseURL)
        try connection.execute(
            """
            UPDATE meme_items
            SET header_payload = NULL,
                note_body = NULL,
                ocr_body = NULL
            """
        )

        let repository = MemeRepository(rootURL: root)
        let migrated = try repository.load()
        XCTAssertEqual(repository.lastDatabaseBackfillMetrics.rowCount, 500)
        XCTAssertEqual(
            repository.lastDatabaseBackfillMetrics.peakResidentRowCount,
            1
        )
        XCTAssertTrue(
            migrated.memes.allSatisfy { $0.decodedStoredTextByteCount == 0 }
        )
        XCTAssertEqual(migrated.memes.last?.ocrText, "OCR-\(body)-499")

        let second = MemeRepository(rootURL: root)
        _ = try second.load()
        XCTAssertEqual(second.lastDatabaseBackfillMetrics.rowCount, 0)
        XCTAssertEqual(second.lastDatabaseBackfillMetrics.peakResidentRowCount, 0)
    }
}
