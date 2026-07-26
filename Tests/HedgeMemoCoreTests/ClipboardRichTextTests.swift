import AppKit
import XCTest

@testable import HedgeMemoCore

@MainActor
final class ClipboardRichTextTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-rich-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCapturePersistsAndRestoresOriginalRTFAndHTMLBytes() throws {
        let root = tempRoot("roundtrip")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        let input = NSPasteboard.withUniqueName()
        let rtf = Data(#"{\rtf1\ansi\b HedgeMemo\b0}"#.utf8)
        let html = Data("<b>HedgeMemo</b>".utf8)
        input.declareTypes([.string, .rtf, .html], owner: nil)
        XCTAssertTrue(input.setString("HedgeMemo", forType: .string))
        XCTAssertTrue(input.setData(rtf, forType: .rtf))
        XCTAssertTrue(input.setData(html, forType: .html))

        store.capturePasteboardContents(input, source: nil)
        let captured = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(captured.text, "HedgeMemo")
        XCTAssertEqual(captured.originalFormats?.map(\.typeIdentifier), [
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.html.rawValue,
        ])

        let reloaded = ClipboardHistoryStore(repository: repository)
        let output = NSPasteboard.withUniqueName()
        XCTAssertTrue(reloaded.copyToPasteboard(try XCTUnwrap(reloaded.entries.first), to: output))
        XCTAssertEqual(output.string(forType: .string), "HedgeMemo")
        XCTAssertEqual(output.data(forType: .rtf), rtf)
        XCTAssertEqual(output.data(forType: .html), html)
    }

    func testPlainTextRecopyReplacesRichFormattingAndRemovesSidecars() throws {
        let root = tempRoot("replace")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        let payload = ClipboardRichTextPayload(
            plainText: "same",
            formats: [ClipboardFormatData(typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("rtf".utf8))]
        )
        XCTAssertTrue(try store.addRichText(payload, source: nil))
        let oldFormats = try XCTUnwrap(store.entries.first?.originalFormats)
        let oldURLs = try oldFormats.map(repository.originalFormatURL(for:))
        XCTAssertTrue(oldURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        XCTAssertFalse(store.addText("same"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.originalFormats ?? [], [])
        XCTAssertTrue(oldURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testDeletingRichEntryRemovesOriginalFormatSidecars() throws {
        let root = tempRoot("delete")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        let payload = ClipboardRichTextPayload(
            plainText: "delete me",
            formats: [ClipboardFormatData(typeIdentifier: NSPasteboard.PasteboardType.html.rawValue, data: Data("<i>x</i>".utf8))]
        )
        XCTAssertTrue(try store.addRichText(payload, source: nil))
        let entry = try XCTUnwrap(store.entries.first)
        let format = try XCTUnwrap(entry.originalFormats?.first)
        let url = try repository.originalFormatURL(for: format)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.delete(id: entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEditingOrMovingToPasswordDiscardsStaleFormatting() throws {
        let root = tempRoot("mutations")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        let rich = ClipboardRichTextPayload(
            plainText: "formatted",
            formats: [
                ClipboardFormatData(
                    typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                    data: Data("format".utf8)
                )
            ]
        )

        XCTAssertTrue(try store.addRichText(rich, source: nil))
        var entry = try XCTUnwrap(store.entries.first)
        var formatURL = try repository.originalFormatURL(for: XCTUnwrap(entry.originalFormats?.first))
        store.updateText(id: entry.id, text: "edited")
        XCTAssertEqual(store.entries.first?.originalFormats ?? [], [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: formatURL.path))

        XCTAssertTrue(try store.addRichText(rich, source: nil))
        entry = try XCTUnwrap(store.entries.first(where: { $0.text == "formatted" }))
        formatURL = try repository.originalFormatURL(for: XCTUnwrap(entry.originalFormats?.first))
        XCTAssertTrue(store.setManualCategory(id: entry.id, key: .builtin(.password)))
        let protected = try XCTUnwrap(store.entries.first(where: { $0.id == entry.id }))
        XCTAssertTrue(protected.isSecret)
        XCTAssertEqual(protected.originalFormats ?? [], [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: formatURL.path))
    }

    func testOversizedAndUnsupportedFormatsThrow() throws {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(rootURL: tempRoot("limits"))
        )
        let oversized = ClipboardRichTextPayload(
            plainText: "large",
            formats: [
                ClipboardFormatData(
                    typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                    data: Data(count: ClipboardRichTextPayload.maxOriginalFormatByteCount + 1)
                )
            ]
        )
        XCTAssertThrowsError(try store.addRichText(oversized, source: nil)) {
            guard case ClipboardRichTextError.originalFormatsTooLarge = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        let unsupported = ClipboardRichTextPayload(
            plainText: "custom",
            formats: [ClipboardFormatData(typeIdentifier: "com.example.private", data: Data([1]))]
        )
        XCTAssertThrowsError(try store.addRichText(unsupported, source: nil)) {
            XCTAssertEqual($0 as? ClipboardRichTextError, .unsupportedRepresentation("com.example.private"))
        }
    }

    func testArchiveRoundTripIncludesOriginalFormatSidecars() throws {
        let sourceRoot = tempRoot("archive-source")
        let sourceRepository = ClipboardHistoryRepository(rootURL: sourceRoot)
        let sourceStore = ClipboardHistoryStore(repository: sourceRepository)
        let html = Data("<strong>Archive</strong>".utf8)
        XCTAssertTrue(
            try sourceStore.addRichText(
                ClipboardRichTextPayload(
                    plainText: "Archive",
                    formats: [
                        ClipboardFormatData(
                            typeIdentifier: NSPasteboard.PasteboardType.html.rawValue,
                            data: html
                        )
                    ]
                ),
                source: nil
            )
        )

        let archiveRoot = tempRoot("archive-file")
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let archiveURL = archiveRoot.appendingPathComponent("rich.zip")
        try MemeArchiveService.export(
            memeSnapshot: nil,
            memeRepository: MemeRepository(rootURL: tempRoot("archive-memes")),
            clipboardSnapshot: sourceStore.snapshot(),
            clipboardRepository: sourceRepository,
            destination: archiveURL
        )
        let extracted = try MemeArchiveService.extract(from: archiveURL)
        defer { MemeArchiveService.removeExtraction(extracted.directory) }

        let targetRepository = ClipboardHistoryRepository(rootURL: tempRoot("archive-target"))
        let targetStore = ClipboardHistoryStore(repository: targetRepository)
        try targetStore.importArchive(
            try XCTUnwrap(extracted.manifest.clipboardSnapshot),
            imagesURL: extracted.directory.appendingPathComponent("clipboard-images", isDirectory: true),
            originalFormatsURL: extracted.directory.appendingPathComponent("clipboard-formats", isDirectory: true)
        )

        let output = NSPasteboard.withUniqueName()
        XCTAssertTrue(targetStore.copyToPasteboard(try XCTUnwrap(targetStore.entries.first), to: output))
        XCTAssertEqual(output.string(forType: .string), "Archive")
        XCTAssertEqual(output.data(forType: .html), html)
    }
}
