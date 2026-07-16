import Foundation
import MemeMemoCore

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

let noteMatch = MemeItem(fileName: "a.png", contentHash: "a", note: "周五下班", ocrText: "")
let ocrMatch = MemeItem(fileName: "b.png", contentHash: "b", note: "未命名", ocrText: "你好世界")
expect(MemeFilter.apply([noteMatch, ocrMatch], categoryID: nil, query: "下班").map(\.id) == [noteMatch.id], "notes must be searchable")
expect(MemeFilter.apply([noteMatch, ocrMatch], categoryID: nil, query: "世界").map(\.id) == [ocrMatch.id], "OCR text must be searchable")

let category = UUID()
let first = MemeItem(fileName: "first.png", contentHash: "1", categoryID: category, sortOrder: 0)
let second = MemeItem(fileName: "second.png", contentHash: "2", categoryID: category, sortOrder: 1)
let other = MemeItem(fileName: "other.png", contentHash: "3", sortOrder: 0)
expect(MemeFilter.apply([second, other, first], categoryID: category, query: "").map(\.id) == [first.id, second.id], "category filtering must preserve order")
expect(noteMatch.matches(query: "  "), "blank queries must retain all entries")

let now = Date(timeIntervalSinceReferenceDate: 1_000)
let pinnedLater = ClipboardEntry(
    kind: .text,
    text: "置顶二",
    contentHash: "p2",
    createdAt: now.addingTimeInterval(20),
    isPinned: true,
    pinnedOrder: 1
)
let regularNewer = ClipboardEntry(
    kind: .text,
    text: "普通新",
    contentHash: "r2",
    createdAt: now.addingTimeInterval(30)
)
let pinnedFirst = ClipboardEntry(
    kind: .text,
    text: "置顶一",
    contentHash: "p1",
    createdAt: now,
    isPinned: true,
    pinnedOrder: 0
)
let regularOlder = ClipboardEntry(
    kind: .text,
    text: "普通旧",
    contentHash: "r1",
    createdAt: now.addingTimeInterval(10)
)
let clipboardOrdered = ClipboardHistoryPolicy.ordered([regularOlder, pinnedLater, regularNewer, pinnedFirst])
expect(clipboardOrdered.map(\.id) == [pinnedFirst.id, pinnedLater.id, regularNewer.id, regularOlder.id], "clipboard entries must sort pinned first, then newest")
expect(ClipboardHistoryPolicy.quickEntry(in: clipboardOrdered, number: 2)?.id == pinnedLater.id, "quick number mapping must follow pinned order")
expect(ClipboardHistoryPolicy.quickEntry(in: clipboardOrdered, number: 9) == nil, "quick number mapping must ignore empty slots")
expect(ClipboardHistoryPolicy.shouldMergeWithLatest(latest: regularNewer, contentHash: "r2"), "consecutive duplicate clipboard entries must merge")
expect(ClipboardHistoryPolicy.idsToTrim(from: clipboardOrdered, maxEntries: 3).isEmpty, "clipboard history keeps a minimum practical limit")
expect(ClipboardEntry(kind: .text, text: "发票报销", contentHash: "q").matches(query: "报销"), "clipboard text must be searchable")

let screenshotSettings = ScreenshotSettings(mode: .smartWindow, remembersLastMode: true)
expect(ScreenshotPolicy.resolvedMode(settings: screenshotSettings, requestedMode: nil) == .smartWindow, "screenshot must use configured mode when no override is requested")
expect(ScreenshotPolicy.resolvedMode(settings: screenshotSettings, requestedMode: .manualSelection) == .manualSelection, "screenshot explicit mode must override settings")
expect(ScreenshotPolicy.settingsAfterCapture(screenshotSettings, usedMode: .manualSelection).mode == .manualSelection, "screenshot settings must remember last mode when enabled")
let fixedModeSettings = ScreenshotSettings(mode: .smartWindow, remembersLastMode: false)
expect(ScreenshotPolicy.settingsAfterCapture(fixedModeSettings, usedMode: .manualSelection).mode == .smartWindow, "screenshot settings must keep fixed mode when remembering is disabled")
expect(ScreenshotHotKeyChoice.controlShiftFive.displayName.contains("Control"), "screenshot hotkey choices must expose a readable label")
expect(ScreenshotSettings().opensEditorAfterCapture, "screenshot editor should open by default")
let noEditorSettings = ScreenshotSettings(opensEditorAfterCapture: false)
expect(!noEditorSettings.opensEditorAfterCapture, "screenshot editor setting must allow direct save")
let customClipboardHotKey = HotKeyDefinition(keyCode: 9, key: "V", command: true, option: true)
expect(customClipboardHotKey.isUsable, "custom hotkey with a modifier must be usable")
expect(customClipboardHotKey.displayName == "Command + Option + V", "custom hotkey display must include modifiers and key")
expect(HotKeyPolicy.conflicts(customClipboardHotKey, customClipboardHotKey), "identical hotkeys must conflict")
expect(!HotKeyPolicy.conflicts(customClipboardHotKey, .defaultScreenshot), "different hotkeys must not conflict")
expect(HotKeyPolicy.label(nil) == "未设置", "missing hotkey must have a stable label")

let swiftSnippet = """
func greet(name: String) -> String {
    return "hi " + name
}
"""
expect(ClipboardCodeDetector.isCode(swiftSnippet), "multi-line source with keywords and braces must be detected as code")
expect(ClipboardCodeDetector.isCode("const total = items.reduce((a, b) => a + b, 0);"), "single-line JS with operators and terminator must be code")
expect(!ClipboardCodeDetector.isCode("今天下午三点开会，请准时参加。"), "ordinary Chinese prose must not be code")
expect(!ClipboardCodeDetector.isCode("Let's meet at 3pm."), "ordinary English prose must not be code")
expect(!ClipboardCodeDetector.isCode("https://github.com/Again0521/memememo"), "a bare link must not be code")

let codeEntry = ClipboardEntry(kind: .text, text: swiftSnippet, contentHash: "code")
let proseEntry = ClipboardEntry(kind: .text, text: "周五下班一起吃饭", contentHash: "prose")
let imageEntry = ClipboardEntry(kind: .image, text: nil, imageFileName: "x.png", contentHash: "img")
expect(codeEntry.contentCategory == .code, "code entry must classify as code")
expect(proseEntry.contentCategory == .text, "prose entry must classify as text")
expect(imageEntry.contentCategory == .image, "image entry must classify as image")
expect(codeEntry.lastUsedAt == nil, "new entries must not carry a last-used time")

let mixed = [codeEntry, proseEntry, imageEntry]
expect(ClipboardHistoryPolicy.ordered(mixed, category: .code).map(\.id) == [codeEntry.id], "category filter must isolate code")
expect(ClipboardHistoryPolicy.ordered(mixed, category: .text).map(\.id) == [proseEntry.id], "category filter must isolate text")
expect(ClipboardHistoryPolicy.ordered(mixed, category: .image).map(\.id) == [imageEntry.id], "category filter must isolate images")
expect(Set(ClipboardHistoryPolicy.ordered(mixed, category: nil).map(\.id)) == Set(mixed.map(\.id)), "no category filter must keep every entry")

expect(HotKeyDefinition.defaultClipboard.displayName == "Command + Shift + V", "clipboard default hotkey must be Command + Shift + V")
var migratedSettings = ClipboardHistorySettings(hotKey: .legacyClipboard, lastCategory: nil)
migratedSettings.normalize()
expect(migratedSettings.hotKey == .defaultClipboard, "legacy Option + Space hotkey must migrate to the new default")
expect(migratedSettings.activeCategory == .text, "missing last category must default to text")
var rememberedSettings = ClipboardHistorySettings()
rememberedSettings.activeCategory = .code
expect(rememberedSettings.lastCategory == .code, "active category must persist into settings")

expect(ClipboardPanelLayout.contentHeight(entryCount: 0, category: .text) == ClipboardPanelLayout.emptyStateHeight, "empty categories must keep the empty-state height")
expect(
    ClipboardPanelLayout.contentHeight(entryCount: 3, category: .text)
        == ClipboardPanelLayout.textRowHeight * 3 + ClipboardPanelLayout.listSpacing * 2,
    "text content height must follow row count"
)
expect(
    ClipboardPanelLayout.contentHeight(entryCount: 4, category: .image)
        == ClipboardPanelLayout.imageCellSide * 2 + ClipboardPanelLayout.imageCellSpacing,
    "four images must lay out as two grid rows"
)
expect(
    ClipboardPanelLayout.contentHeight(entryCount: 2, category: .code)
        > ClipboardPanelLayout.contentHeight(entryCount: 2, category: .text),
    "code rows must be taller than text rows"
)
expect(
    ClipboardPanelLayout.panelHeight(entryCount: 1_000, category: .text, availableHeight: 600) == 600,
    "panel height must clamp to the available screen height"
)
expect(
    ClipboardPanelLayout.panelHeight(entryCount: 0, category: .image, availableHeight: 600)
        == ClipboardPanelLayout.chromeHeight + ClipboardPanelLayout.emptyStateHeight,
    "panel height must keep a sensible minimum"
)

// Regression: mutating settings used to recurse through didSet until the stack
// overflowed (max-entries stepper crash, post-screenshot crash).
await MainActor.run {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("memememo-whitebox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let clipboardStore = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: tempRoot))
    clipboardStore.settings.maxEntries = 200
    expect(clipboardStore.settings.maxEntries == 200, "changing max entries must not crash and must persist")
    clipboardStore.settings.activeCategory = .image
    expect(clipboardStore.settings.activeCategory == .image, "changing the active category must not crash")

    let suiteName = "memememo-whitebox-screenshot"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let screenshotStore = ScreenshotSettingsStore(defaults: defaults)
    screenshotStore.markCapture(mode: .manualSelection)
    expect(screenshotStore.settings.mode == .manualSelection, "marking a capture must not crash and must remember the mode")
    defaults.removePersistentDomain(forName: suiteName)
}

print("MemeMemo whitebox checks passed (46 assertions).")
