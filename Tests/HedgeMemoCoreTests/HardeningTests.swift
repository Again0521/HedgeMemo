import AppKit
import XCTest

@testable import HedgeMemoCore

/// Regression coverage for the 1.2.0 privacy/robustness hardening: concealed
/// clipboard content, oversized captures, unusable hot keys, path-traversal in
/// archive imports, and bounded custom-category regex matching.
@MainActor
final class HardeningTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-harden-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeClipboardStore() -> ClipboardHistoryStore {
        ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: tempRoot("clip")))
    }

    // MARK: - Concealed / transient clipboard

    func testConcealedPasteboardIsRecognized() {
        let concealed = NSPasteboard.withUniqueName()
        concealed.declareTypes([NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), .string], owner: nil)
        concealed.setString("hunter2", forType: .string)
        XCTAssertTrue(ClipboardHistoryStore.isPrivatePasteboard(concealed))

        let ordinary = NSPasteboard.withUniqueName()
        ordinary.declareTypes([.string], owner: nil)
        ordinary.setString("just text", forType: .string)
        XCTAssertFalse(ClipboardHistoryStore.isPrivatePasteboard(ordinary))
    }

    // MARK: - Size caps

    func testOversizedTextIsNotRecorded() {
        let store = makeClipboardStore()
        let huge = String(repeating: "a", count: ClipboardHistoryStore.maxTextByteCount + 1)
        XCTAssertFalse(store.addText(huge), "text past the cap must be skipped, not stored")
        XCTAssertTrue(store.entries.isEmpty)

        XCTAssertTrue(store.addText("刚刚好"), "ordinary text is still recorded")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testOversizedImageIsNotRecorded() {
        let store = makeClipboardStore()
        let oversized = ImageAssetData(
            data: Data(count: ClipboardHistoryStore.maxImageByteCount + 1),
            fileExtension: "png"
        )
        XCTAssertFalse(store.addImageData(oversized))
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Hot keys

    func testShiftOnlyHotKeyIsNotUsable() {
        XCTAssertFalse(HotKeyDefinition(keyCode: 9, key: "V", shift: true).isUsable)
        XCTAssertTrue(HotKeyDefinition(keyCode: 9, key: "V", command: true, shift: true).isUsable)
        XCTAssertTrue(HotKeyDefinition(keyCode: 9, key: "V", control: true).isUsable)
    }

    // MARK: - Archive path traversal

    func testArchiveRejectsUnsafeFileNames() {
        let base = URL(fileURLWithPath: "/tmp/extract/clipboard-images", isDirectory: true)
        XCTAssertNil(MemeArchiveService.safeContainedURL(base: base, fileName: "../../etc/passwd"))
        XCTAssertNil(MemeArchiveService.safeContainedURL(base: base, fileName: "a/b.png"))
        XCTAssertNil(MemeArchiveService.safeContainedURL(base: base, fileName: ""))
        XCTAssertNil(MemeArchiveService.safeContainedURL(base: base, fileName: ".hidden"))
        XCTAssertEqual(
            MemeArchiveService.safeContainedURL(base: base, fileName: "abc.png")?.lastPathComponent,
            "abc.png"
        )
    }

    // MARK: - Custom category regex

    func testCustomCategoryMatchesAreBoundedAndValid() {
        let category = CustomClipboardCategory(name: "Ticket", pattern: "^JIRA-[0-9]+")
        XCTAssertTrue(category.isPatternValid)
        XCTAssertTrue(category.matches("JIRA-1234 fix the thing"))
        XCTAssertFalse(category.matches("no ticket here"))

        let invalid = CustomClipboardCategory(name: "Broken", pattern: "(")
        XCTAssertFalse(invalid.isPatternValid)
        XCTAssertFalse(invalid.matches("anything"))
    }
}
