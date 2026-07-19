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
}
