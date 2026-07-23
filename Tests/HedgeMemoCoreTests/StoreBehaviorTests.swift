import AppKit
import XCTest

@testable import HedgeMemoCore

/// Exercises the stateful stores end to end against throwaway on-disk
/// repositories, so persistence and mutation paths are covered too.
@MainActor
final class StoreBehaviorTests: XCTestCase {
    /// Each temp root registers its own teardown so cleanup captures only a
    /// `Sendable` URL — no main-actor state leaks into the nonisolated teardown.
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeMemeStore() -> MemeStore {
        MemeStore(repository: MemeRepository(rootURL: tempRoot("meme")))
    }

    private func makeClipboardStore() -> ClipboardHistoryStore {
        ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: tempRoot("clip")))
    }

    // MARK: - MemeStore

    func testMemeReorderMovesDraggedItemIntoTargetSlot() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.1, size: 6), note: "一"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.5, size: 8), note: "二"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.9, size: 10), note: "三"))
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["一", "二", "三"])

        let first = store.filteredMemes(query: "")[0].id
        let third = store.filteredMemes(query: "")[2].id
        store.reorder(draggedID: first, over: third)
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["二", "三", "一"])

        store.reorderToEnd(draggedID: store.filteredMemes(query: "")[0].id, categoryID: nil)
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["三", "一", "二"])
    }

    func testDuplicateMemeImageIsRejected() {
        let store = makeMemeStore()
        let image = Fixture.solidImage(0.3, size: 7)
        XCTAssertTrue(store.addImage(image, note: "原图"))
        XCTAssertFalse(store.addImage(image, note: "重复"), "identical bytes must not be stored twice")
        XCTAssertEqual(store.filteredMemes(query: "").count, 1)
    }

    func testGIFPayloadKeepsItsFormat() {
        let store = makeMemeStore()
        let payload = ImageAssetData(data: Fixture.gifBytes, fileExtension: "png")
        XCTAssertEqual(payload.fileExtension, "gif", "GIF magic bytes override the suggested extension")
        XCTAssertTrue(store.addImageData(payload, note: "动态"))
        let gif = store.filteredMemes(query: "动态").first!
        XCTAssertTrue(gif.fileName.hasSuffix(".gif"))
        XCTAssertEqual(try? Data(contentsOf: store.imageURL(for: gif)), Fixture.gifBytes)
    }

    func testMemeCaptureServiceConsumesClipboardImages() {
        let pasteboard = NSPasteboard.withUniqueName()
        let payload = ImageAssetData(data: Fixture.gifBytes, fileExtension: "gif")
        var captured: ImageAssetData?
        let service = ClipboardCaptureService(pasteboard: pasteboard) { captured = $0 }
        service.start()
        defer { service.stop() }

        XCTAssertTrue(payload.write(to: pasteboard))
        service.inspectPasteboard()

        XCTAssertEqual(captured?.data, Fixture.gifBytes)
        XCTAssertEqual(captured?.fileExtension, "gif")
    }

    func testBundledSampleMemesLoadSeedInOrderAndDedup() throws {
        // Repo root is three levels up from Tests/HedgeMemoCoreTests/<thisFile>.
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HedgeMemo/Resources")
        // Samples may be provided in any common format, matching the seeder.
        let extensions = ["png", "jpg", "jpeg", "gif"]
        let urls = try ["DefaultMeme1", "DefaultMeme2", "DefaultMeme3"].map { name -> URL in
            let url = extensions
                .map { resources.appendingPathComponent("\(name).\($0)") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            return try XCTUnwrap(url, "\(name).* must be present to bundle")
        }

        let store = makeMemeStore()
        for url in urls {
            let payload = try XCTUnwrap(ImageAssetData(fileURL: url))
            XCTAssertTrue(store.addImageData(payload))
        }
        XCTAssertEqual(store.filteredMemes(query: "").count, 3, "all three samples seed")

        // Re-seeding the identical files must not duplicate them.
        for url in urls {
            let payload = try XCTUnwrap(ImageAssetData(fileURL: url))
            XCTAssertFalse(store.addImageData(payload))
        }
        XCTAssertEqual(store.filteredMemes(query: "").count, 3)
    }

    func testMovingAMemeAdoptsTheTargetCategory() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.2, size: 6), note: "图"))
        let id = store.filteredMemes(query: "")[0].id
        let category = store.addCategory(name: "分组")
        XCTAssertNotNil(category)
        store.move(ids: [id], to: category)
        XCTAssertEqual(store.memes.first(where: { $0.id == id })?.categoryID, category)
    }

    // MARK: - ClipboardHistoryStore

    func testConsecutiveDuplicateTextIsNotStoredTwice() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("独立内容"))
        XCTAssertFalse(store.addText("独立内容"), "a repeat of the latest entry merges instead of duplicating")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testPinAndDesktopPinAreIndependentAndPersist() {
        let root = tempRoot("clip-persist")
        let store = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertTrue(store.addText("固定状态"))
        let id = store.entries.first!.id

        store.togglePinned(id: id)
        XCTAssertTrue(store.entries.first!.isPinned)
        XCTAssertNotEqual(store.entries.first!.isDesktopPinned, true, "list pinning must not create a desktop note")

        store.toggleDesktopPinned(id: id)
        XCTAssertTrue(store.entries.first!.isPinned, "desktop pinning must not clear list pinning")
        XCTAssertEqual(store.entries.first!.isDesktopPinned, true)

        let reloaded = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertEqual(reloaded.entries.first?.isPinned, true, "list pin state must persist")
        XCTAssertEqual(reloaded.entries.first?.isDesktopPinned, true, "desktop note state must persist independently")
    }

    func testDesktopPinOrderIsFirstComeAndRepinMovesToEnd() {
        let root = tempRoot("desktop-order")
        let store = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertTrue(store.addText("第一条"))
        XCTAssertTrue(store.addText("第二条"))
        let firstID = store.entries.first(where: { $0.text == "第一条" })!.id
        let secondID = store.entries.first(where: { $0.text == "第二条" })!.id

        store.toggleDesktopPinned(id: firstID)
        store.toggleDesktopPinned(id: secondID)
        XCTAssertEqual(ClipboardHistoryPolicy.desktopPinnedEntries(store.entries).map(\.id), [firstID, secondID])

        store.toggleDesktopPinned(id: firstID)
        store.toggleDesktopPinned(id: firstID)
        XCTAssertEqual(ClipboardHistoryPolicy.desktopPinnedEntries(store.entries).map(\.id), [secondID, firstID])

        let reloaded = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertEqual(ClipboardHistoryPolicy.desktopPinnedEntries(reloaded.entries).map(\.id), [secondID, firstID])
    }

    func testScreenshotsStayInTheirDedicatedCategory() {
        let store = makeClipboardStore()
        let payload = ImageAssetData(data: Fixture.solidImage(0.4, size: 10).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot))
        XCTAssertEqual(store.orderedEntries(key: .builtin(.screenshot)).count, 1)
        XCTAssertTrue(store.orderedEntries(key: .builtin(.image)).isEmpty, "screenshots must not mix with copied images")
    }

    func testDisablingACategoryClearsAndBlocksIt() {
        let store = makeClipboardStore()
        let payload = ImageAssetData(data: Fixture.solidImage(0.4, size: 10).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot))
        store.setCategory(.builtin(.screenshot), enabled: false)
        XCTAssertTrue(store.orderedEntries(key: .builtin(.screenshot)).isEmpty, "disabling clears existing records")
        XCTAssertFalse(
            store.addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot),
            "a disabled category records nothing further"
        )
    }

    func testUpdateTextEditsContentAndRecomputesHash() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("原始内容"))
        let id = store.entries.first!.id
        let originalHash = store.entries.first!.contentHash

        store.updateText(id: id, text: "编辑后的内容")

        let edited = store.entries.first!
        XCTAssertEqual(edited.text, "编辑后的内容")
        XCTAssertNotEqual(edited.contentHash, originalHash, "the hash must track the edited text, not the original")
    }

    func testUpdateTextIgnoresImageEntries() {
        let store = makeClipboardStore()
        let payload = ImageAssetData(data: Fixture.solidImage(0.4, size: 10).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(payload))
        let id = store.entries.first!.id

        store.updateText(id: id, text: "不应生效")

        XCTAssertNil(store.entries.first?.text, "an image entry has no editable text body")
    }

    func testUpdateTextIgnoresUnknownID() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("内容"))
        let before = store.entries

        store.updateText(id: UUID(), text: "不存在的条目")

        XCTAssertEqual(store.entries, before)
    }

    func testUpdateTextPersists() {
        let root = tempRoot("clip-edit-persist")
        let store = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertTrue(store.addText("原始内容"))
        let id = store.entries.first!.id
        store.updateText(id: id, text: "持久化后的内容")

        let reloaded = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertEqual(reloaded.entries.first?.text, "持久化后的内容")
    }

    func testSeedEntriesAppendInGivenOrderNewestFirst() {
        let store = makeClipboardStore()
        let now = Date()
        let lines = ["第一条", "第二条", "第三条"]
        let seeds = lines.enumerated().map { index, line in
            ClipboardEntry(
                kind: .text,
                text: line,
                contentHash: "seed\(index)",
                createdAt: now.addingTimeInterval(-Double(index))
            )
        }
        store.addSeedEntries(seeds)
        // Index 0 has the latest timestamp, so it sorts to the top.
        XCTAssertEqual(store.orderedEntries().compactMap(\.text), lines)
    }

    func testEmptySeedIsANoOp() {
        let store = makeClipboardStore()
        store.addSeedEntries([])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRepositoriesReportPersistenceOnlyAfterFirstWrite() {
        let clipRepo = ClipboardHistoryRepository(rootURL: tempRoot("clip-flag"))
        XCTAssertFalse(clipRepo.hasPersistedHistory, "a fresh install has no snapshot yet")
        let clipStore = ClipboardHistoryStore(repository: clipRepo)
        XCTAssertFalse(clipRepo.hasPersistedHistory, "loading an empty store must not write a snapshot")
        XCTAssertTrue(clipStore.addText("首次内容"))
        XCTAssertTrue(clipRepo.hasPersistedHistory, "the first write marks the store as used")

        let memeRepo = MemeRepository(rootURL: tempRoot("meme-flag"))
        XCTAssertFalse(memeRepo.hasPersistedLibrary)
        let memeStore = MemeStore(repository: memeRepo)
        XCTAssertFalse(memeRepo.hasPersistedLibrary)
        XCTAssertTrue(memeStore.addImage(Fixture.solidImage(0.3, size: 6), note: "图"))
        XCTAssertTrue(memeRepo.hasPersistedLibrary)
    }

    func testDeleteAndClearHistory() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("甲"))
        XCTAssertTrue(store.addText("乙"))
        let firstID = store.entries.first!.id
        store.delete(id: firstID)
        XCTAssertFalse(store.entries.contains { $0.id == firstID })
        store.clearHistory()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearHistoryCanTargetSelectedCategories() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("普通中文内容"))
        XCTAssertTrue(store.addText("let answer = 42;"))
        XCTAssertTrue(store.addText("https://example.com/path"))

        let selected: Set<ClipboardCategoryKey> = [.builtin(.code), .builtin(.link)]
        XCTAssertEqual(store.entryCount(matching: selected), 2)
        store.clearHistory(matching: selected)

        XCTAssertEqual(store.entries.compactMap(\.text), ["普通中文内容"])
    }
}
