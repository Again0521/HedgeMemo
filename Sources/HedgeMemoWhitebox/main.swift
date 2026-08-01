import AppKit
import Foundation
import HedgeMemoCore

nonisolated(unsafe) private var assertionCount = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

private func solidImage(_ shade: CGFloat, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSColor(calibratedWhite: shade, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.unlockFocus()
    return image
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
expect(ClipboardHistoryPolicy.idsToTrim(from: clipboardOrdered, maxEntries: 3).isEmpty, "clipboard history keeps a minimum practical limit")
expect(ClipboardEntry(kind: .text, text: "发票报销", contentHash: "q").matches(query: "报销"), "clipboard text must be searchable")
let desktopPinned = ClipboardEntry(
    kind: .text,
    text: "桌面固定",
    contentHash: "desktop",
    isDesktopPinned: true,
    desktopPinnedOrder: 0
)
let desktopOrderingCandidates = (0..<10).map {
    ClipboardEntry(kind: .text, text: "普通\($0)", contentHash: "ordinary-\($0)", createdAt: now.addingTimeInterval(Double($0)))
} + [desktopPinned]
expect(
    ClipboardHistoryPolicy.ordered(desktopOrderingCandidates)[9].id == desktopPinned.id,
    "desktop-pinned entries must begin at the tenth visible position"
)

let screenshotSettings = ScreenshotSettings(mode: .smartWindow, remembersLastMode: true)
expect(ScreenshotPolicy.resolvedMode(settings: screenshotSettings, requestedMode: nil) == .smartWindow, "screenshot must use configured mode when no override is requested")
expect(ScreenshotSettings().mode == .smartWindow, "new screenshot settings must default to smart window")
expect(ScreenshotSettings().hotKey == .defaultScreenshot, "new screenshot settings must default to Command + Shift + P")
expect(ScreenshotSettings().hotKeyChoice == .commandShiftP, "new screenshot settings must expose the Command + Shift + P choice")
var legacyScreenshotSettings = ScreenshotSettings(
    mode: .manualSelection,
    remembersLastMode: true,
    hotKeyChoice: .controlShiftFive,
    hotKey: .legacyScreenshot
)
legacyScreenshotSettings.normalize()
expect(legacyScreenshotSettings.hotKey == .defaultScreenshot, "legacy screenshot shortcut must migrate to Command + Shift + P")
expect(legacyScreenshotSettings.hotKeyChoice == .commandShiftP, "legacy screenshot shortcut choice must migrate to Command + Shift + P")
expect(ScreenshotPolicy.resolvedMode(settings: screenshotSettings, requestedMode: .manualSelection) == .manualSelection, "screenshot explicit mode must override settings")
expect(ScreenshotPolicy.settingsAfterCapture(screenshotSettings, usedMode: .manualSelection).mode == .manualSelection, "screenshot settings must remember last mode when enabled")
let fixedModeSettings = ScreenshotSettings(mode: .smartWindow, remembersLastMode: false)
expect(ScreenshotPolicy.settingsAfterCapture(fixedModeSettings, usedMode: .manualSelection).mode == .smartWindow, "screenshot settings must keep fixed mode when remembering is disabled")
expect(ScreenshotHotKeyChoice.controlShiftFive.displayName.contains("Control"), "screenshot hotkey choices must expose a readable label")
expect(ScreenshotSettings().opensEditorAfterCapture, "screenshot editor should open by default")
let noEditorSettings = ScreenshotSettings(opensEditorAfterCapture: false)
expect(!noEditorSettings.opensEditorAfterCapture, "screenshot editor setting must allow direct save")
expect(MemePanelSettings().hotKey == .defaultMemePanel, "meme panel must default to Command + Shift + E")
let customClipboardHotKey = HotKeyDefinition(keyCode: 9, key: "V", command: true, option: true)
expect(customClipboardHotKey.isUsable, "custom hotkey with a modifier must be usable")
expect(customClipboardHotKey.displayName == "Command + Option + V", "custom hotkey display must include modifiers and key")
expect(HotKeyPolicy.conflicts(customClipboardHotKey, customClipboardHotKey), "identical hotkeys must conflict")
expect(!HotKeyPolicy.conflicts(customClipboardHotKey, .defaultScreenshot), "different hotkeys must not conflict")
expect(HotKeyPolicy.label(nil) == L10n.text("未设置"), "missing hotkey must have a stable label")

let swiftSnippet = """
func greet(name: String) -> String {
    return "hi " + name
}
"""
expect(ClipboardCodeDetector.isCode(swiftSnippet), "multi-line source with keywords and braces must be detected as code")
expect(ClipboardCodeDetector.isCode("const total = items.reduce((a, b) => a + b, 0);"), "single-line JS with operators and terminator must be code")
expect(!ClipboardCodeDetector.isCode("今天下午三点开会，请准时参加。"), "ordinary Chinese prose must not be code")
expect(!ClipboardCodeDetector.isCode("Let's meet at 3pm."), "ordinary English prose must not be code")
expect(!ClipboardCodeDetector.isCode("https://github.com/Again0521/hedgememo"), "a bare link must not be code")
let technicalWorkLog = """
I'll work through these tasks and inspect the relevant code first.

## Resource optimization
- Background: set `timer.tolerance = 0.25` to coalesce wakeups.
- Foreground: reuse the existing native material view.
- Verification: clean build and tests pass.

This is an implementation report with API names, not source code.
"""
expect(!ClipboardCodeDetector.isCode(technicalWorkLog), "long technical work logs with embedded snippets must stay text")

let codeEntry = ClipboardEntry(kind: .text, text: swiftSnippet, contentHash: "code")
let proseEntry = ClipboardEntry(kind: .text, text: "周五下班一起吃饭", contentHash: "prose")
let imageEntry = ClipboardEntry(kind: .image, text: nil, imageFileName: "x.png", contentHash: "img")
let linkEntry = ClipboardEntry(kind: .text, text: "https://github.com/Again0521/hedgememo", contentHash: "url")
expect(codeEntry.contentCategory == .code, "code entry must classify as code")
expect(proseEntry.contentCategory == .text, "prose entry must classify as text")
expect(imageEntry.contentCategory == .image, "image entry must classify as image")
expect(linkEntry.contentCategory == .link, "URL entry must classify as link")
expect(ClipboardLinkDetector.isLink("www.example.com/path"), "www-prefixed domains must count as links")
expect(!ClipboardLinkDetector.isLink("今天 example 下午三点"), "prose containing dots must not count as a link")
expect(codeEntry.lastUsedAt == nil, "new entries must not carry a last-used time")
expect(codeEntry.useCount == nil, "new entries must not carry a use count")

let mixed = [codeEntry, proseEntry, imageEntry, linkEntry]
expect(ClipboardHistoryPolicy.ordered(mixed, key: .builtin(.code)).map(\.id) == [codeEntry.id], "category filter must isolate code")
expect(ClipboardHistoryPolicy.ordered(mixed, key: .builtin(.text)).map(\.id) == [proseEntry.id], "category filter must isolate text")
expect(ClipboardHistoryPolicy.ordered(mixed, key: .builtin(.image)).map(\.id) == [imageEntry.id], "category filter must isolate images")
expect(ClipboardHistoryPolicy.ordered(mixed, key: .builtin(.link)).map(\.id) == [linkEntry.id], "category filter must isolate links")
expect(Set(ClipboardHistoryPolicy.ordered(mixed, key: nil).map(\.id)) == Set(mixed.map(\.id)), "no category filter must keep every entry")

let regexCategory = CustomClipboardCategory(name: "GitHub", pattern: "github\\.com")
expect(regexCategory.isPatternValid, "a valid regex pattern must validate")
expect(!CustomClipboardCategory(name: "坏", pattern: "([").isPatternValid, "an invalid regex pattern must not validate")
expect(
    ClipboardHistoryPolicy.ordered(mixed, key: .custom(regexCategory.id), customCategories: [regexCategory]).map(\.id) == [linkEntry.id],
    "custom regex categories must filter text entries"
)

expect(HotKeyDefinition.defaultClipboard.displayName == "Command + Shift + V", "clipboard default hotkey must be Command + Shift + V")
var migratedSettings = ClipboardHistorySettings(hotKey: .legacyClipboard, lastCategory: nil)
migratedSettings.normalize()
expect(migratedSettings.hotKey == .defaultClipboard, "legacy Option + Space hotkey must migrate to the new default")
expect(migratedSettings.activeCategoryKey == .builtin(.text), "missing last category must default to text")
expect(
    migratedSettings.categoryOrder == ["text", "code", "link", "image", "screenshot", "password"],
    "default category order must include the dedicated screenshot and password categories"
)
var rememberedSettings = ClipboardHistorySettings()
rememberedSettings.activeCategoryKey = .builtin(.code)
expect(rememberedSettings.lastCategory == "code", "active category must persist into settings")

var customSettings = ClipboardHistorySettings(customCategories: [regexCategory])
customSettings.normalize()
expect(
    customSettings.orderedCategoryKeys.last == .custom(regexCategory.id),
    "custom categories must join the category order"
)
customSettings.activeCategoryKey = .custom(regexCategory.id)
customSettings.customCategories = []
customSettings.normalize()
expect(customSettings.activeCategoryKey == .builtin(.text), "removing the active custom category must fall back to text")
expect(!customSettings.orderedCategoryKeys.contains(.custom(regexCategory.id)), "removed custom categories must leave the order")

let textEntries = [proseEntry, proseEntry, proseEntry]
expect(
    ClipboardPanelLayout.contentHeight(for: [], key: .builtin(.text)) == ClipboardPanelLayout.emptyStateHeight,
    "empty categories must keep the empty-state height"
)
expect(
    ClipboardPanelLayout.contentHeight(for: textEntries, key: .builtin(.text))
        == ClipboardPanelLayout.textRowHeight * 3 + ClipboardPanelLayout.listSpacing * 2,
    "text content height must follow row count"
)
expect(
    ClipboardPanelLayout.contentHeight(for: [imageEntry, imageEntry, imageEntry, imageEntry], key: .builtin(.image))
        == ClipboardPanelLayout.imageCellSide * 2 + ClipboardPanelLayout.imageCellSpacing,
    "four images must lay out as two grid rows"
)
expect(ClipboardPanelPagination.pageSize(for: .builtin(.code)) == 60, "code rows must render in bounded pages")
expect(ClipboardPanelPagination.pageSize(for: .builtin(.image)) == 48, "image rows must render in bounded pages")
expect(ClipboardPanelPagination.pageSize(for: .builtin(.text)) == 300, "plain rows must render in bounded pages")
expect(ClipboardPanelLayout.previewLineCount("single line") == 1, "single-line code must count one preview line")
expect(ClipboardPanelLayout.previewLineCount("a\nb\nc\nd\ne") == 3, "long snippets must clamp to three preview lines")
expect(
    ClipboardPanelLayout.codePreviewLines("one\n\n\n") == ["one"],
    "blank code lines must not reserve phantom preview rows"
)
expect(
    ClipboardPanelLayout.codeRowHeight(lineCount: 1) < ClipboardPanelLayout.codeRowHeight(lineCount: 3),
    "one-line code rows must be shorter than three-line rows"
)
let shortCode = ClipboardEntry(kind: .text, text: "let a = 1;", contentHash: "c1")
expect(
    ClipboardPanelLayout.contentHeight(for: [shortCode], key: .builtin(.code))
        == ClipboardPanelLayout.codeRowHeight(lineCount: 1),
    "code content height must follow per-entry line counts"
)
expect(
    ClipboardPanelLayout.panelHeight(contentHeight: 10_000, availableHeight: 600) == 600,
    "panel height must clamp to the available screen height"
)
expect(
    ClipboardPanelLayout.panelHeight(contentHeight: 0, availableHeight: 600)
        == ClipboardPanelLayout.chromeHeight + ClipboardPanelLayout.emptyStateHeight,
    "panel height must keep a sensible minimum"
)
expect(
    ClipboardPanelLayout.constrainedOriginY(
        preferredTop: 760,
        height: 600,
        visibleMinY: 100,
        visibleMaxY: 760
    ) == 148,
    "tall categories must remain fully inside the visible screen"
)
expect(
    ClipboardPanelLayout.constrainedOriginY(
        preferredTop: 400,
        height: 200,
        visibleMinY: 100,
        visibleMaxY: 760
    ) == 200,
    "short categories must preserve their prior top edge"
)

// Regression: mutating settings used to recurse through didSet until the stack
// overflowed (max-entries stepper crash, post-screenshot crash).
await MainActor.run {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgememo-whitebox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let clipboardStore = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: tempRoot))
    clipboardStore.settings.maxEntries = 200
    expect(clipboardStore.settings.maxEntries == 200, "changing max entries must not crash and must persist")
    clipboardStore.settings.activeCategoryKey = .builtin(.image)
    expect(clipboardStore.settings.activeCategoryKey == .builtin(.image), "changing the active category must not crash")

    expect(clipboardStore.addText("独立固定状态"), "seed clipboard entry for pin-state checks")
    let pinStateID = clipboardStore.entries.first!.id
    clipboardStore.togglePinned(id: pinStateID)
    expect(clipboardStore.entries.first!.isPinned, "clipboard pinning must set only the clipboard ordering state")
    expect(clipboardStore.entries.first!.isDesktopPinned != true, "clipboard pinning must not create a desktop note")
    clipboardStore.toggleDesktopPinned(id: pinStateID)
    expect(clipboardStore.entries.first!.isPinned, "desktop pinning must not clear clipboard ordering pinning")
    expect(clipboardStore.entries.first!.isDesktopPinned == true, "desktop pinning must use its own state")
    let reloadedClipboardStore = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: tempRoot))
    expect(reloadedClipboardStore.entries.first?.isPinned == true, "clipboard pin state must persist")
    expect(reloadedClipboardStore.entries.first?.isDesktopPinned == true, "desktop note state must persist independently")
    expect(reloadedClipboardStore.addText("重复项目"), "seed a clipboard item for global deduplication")
    let repeatedID = reloadedClipboardStore.orderedEntries().first!.id
    expect(reloadedClipboardStore.addText("中间项目"), "seed a different item between duplicate captures")
    expect(!reloadedClipboardStore.addText("重复项目"), "a non-consecutive duplicate must reuse its existing item")
    expect(reloadedClipboardStore.orderedEntries().first?.id == repeatedID, "reused clipboard content must move forward without becoming pinned")

    let suiteName = "hedgememo-whitebox-screenshot"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let screenshotStore = ScreenshotSettingsStore(defaults: defaults)
    screenshotStore.markCapture(mode: .manualSelection)
    expect(screenshotStore.settings.mode == .manualSelection, "marking a capture must not crash and must remember the mode")
    defaults.removePersistentDomain(forName: suiteName)

    // Regression: dragging a meme reorders the backing array, but sortOrder was
    // re-derived from stale values so the visible order never changed.
    let memeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgememo-whitebox-memes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: memeRoot) }
    let memeStore = MemeStore(repository: MemeRepository(rootURL: memeRoot))
    expect(memeStore.addImage(solidImage(0.1, size: 6), note: "一"), "seed meme one")
    expect(memeStore.addImage(solidImage(0.5, size: 8), note: "二"), "seed meme two")
    expect(memeStore.addImage(solidImage(0.9, size: 10), note: "三"), "seed meme three")
    let initialOrder = memeStore.filteredMemes(query: "").map(\.note)
    expect(initialOrder == ["一", "二", "三"], "memes must start in insertion order")
    let first = memeStore.filteredMemes(query: "")[0].id
    let third = memeStore.filteredMemes(query: "")[2].id
    memeStore.reorder(draggedID: first, over: third)
    let reordered = memeStore.filteredMemes(query: "").map(\.note)
    expect(reordered == ["二", "三", "一"], "a live reorder must drop the dragged meme into the target's slot")
    let second = memeStore.filteredMemes(query: "")[0].id
    memeStore.reorder(draggedID: second, over: third)
    expect(
        memeStore.filteredMemes(query: "").map(\.note) == ["三", "二", "一"],
        "dragging backwards must also land in the target's slot"
    )
    memeStore.reorderToEnd(draggedID: third, categoryID: nil)
    expect(
        memeStore.filteredMemes(query: "").map(\.note) == ["二", "一", "三"],
        "the explicit end drop target must move an item to the list tail"
    )
    // Regression: in the “全部” view most drags cross category boundaries; the
    // old guard silently ignored them, which read as "release does nothing".
    let reorderCategory = memeStore.addCategory(name: "拖拽分类")
    expect(reorderCategory != nil, "seed category for cross-category reorder")
    memeStore.move(ids: [third], to: reorderCategory)
    memeStore.reorder(draggedID: third, over: second)
    expect(
        memeStore.filteredMemes(query: "").map(\.note) == ["三", "二", "一"],
        "a cross-category live reorder must still land in the target's slot"
    )
    expect(
        memeStore.memes.first(where: { $0.id == third })?.categoryID == nil,
        "a cross-category live reorder must adopt the target's category"
    )

    let gifBytes = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
    let gifPayload = ImageAssetData(data: gifBytes, fileExtension: "png")
    expect(gifPayload.fileExtension == "gif", "GIF magic bytes must override an incorrect suggested extension")
    expect(memeStore.addImageData(gifPayload, note: "动态"), "animated GIF bytes must be accepted without PNG conversion")
    let gifMeme = memeStore.filteredMemes(query: "动态").first!
    expect(
        gifMeme.fileName.hasSuffix(".gif") && (try? Data(contentsOf: memeStore.imageURL(for: gifMeme))) == gifBytes,
        "GIF storage must preserve the original format and bytes"
    )

    // Screenshot completion uses this exact encoded-payload path. Exercise it
    // on an isolated pasteboard so the user's real clipboard is untouched.
    let testPasteboard = NSPasteboard.withUniqueName()
    let screenshotBytes = solidImage(0.4, size: 12).pngData!
    let screenshotPayload = ImageAssetData(data: screenshotBytes, fileExtension: "png")
    expect(screenshotPayload.write(to: testPasteboard), "screenshot PNG must be writable to the pasteboard")
    expect(
        ImageAssetData.read(from: testPasteboard)?.fileExtension == "png",
        "a completed screenshot must be readable from the pasteboard as PNG"
    )

    expect(
        clipboardStore.addImageData(screenshotPayload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot),
        "completed screenshots must be stored in their dedicated clipboard category"
    )
    expect(
        clipboardStore.orderedEntries(key: .builtin(.screenshot)).count == 1,
        "the screenshot category must not mix with ordinary copied images"
    )

    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgememo-whitebox-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    do {
        try MemeArchiveService.export(
            memeSnapshot: memeStore.snapshot(),
            memeRepository: memeStore.repository,
            clipboardSnapshot: clipboardStore.snapshot(),
            clipboardRepository: clipboardStore.repository,
            destination: archiveURL
        )
        let extracted = try MemeArchiveService.extract(from: archiveURL)
        defer { MemeArchiveService.removeExtraction(extracted.directory) }
        expect(extracted.manifest.formatVersion == MemeArchiveManifest.formatVersion, "ZIP exports must carry the current HedgeMemo manifest")
        var archivedMemes: [MemeItem] = []
        var archivedClipboardEntries: [ClipboardEntry] = []
        try MemeArchiveService.forEachMeme(in: extracted) { archivedMemes.append($0) }
        try MemeArchiveService.forEachClipboardEntry(in: extracted) {
            archivedClipboardEntries.append($0)
        }
        expect(!archivedMemes.isEmpty, "ZIP exports must retain selected meme data")
        expect(archivedClipboardEntries.contains(where: { $0.origin == .hedgeMemoScreenshot }), "ZIP exports must retain the screenshot category")
    } catch {
        expect(false, "HedgeMemo ZIP export/import must round-trip: \(error.localizedDescription)")
    }

    clipboardStore.setCategory(.builtin(.screenshot), enabled: false)
    expect(
        clipboardStore.orderedEntries(key: .builtin(.screenshot)).isEmpty,
        "disabling a category must clear its existing records and hide it"
    )
    expect(
        !clipboardStore.addImageData(screenshotPayload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot),
        "a disabled screenshot category must not record future screenshots"
    )

    // Meme capture pauses clipboard history recording.
    let clipRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgememo-whitebox-clip-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: clipRoot) }
    let pausedStore = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: clipRoot))
    pausedStore.isRecordingPaused = true
    expect(pausedStore.isRecordingPaused, "recording pause flag must be settable for meme capture")

    // MARK: Password category & PIN lock

    let secretRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgememo-whitebox-secret-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: secretRoot) }
    let secretStore = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: secretRoot))

    let secretEntry = ClipboardEntry(
        kind: .text,
        text: "hmenc.v1:ZmFrZQ==",
        contentHash: "hash-secret",
        origin: .concealedPassword
    )
    expect(secretEntry.contentCategory == .password, "a concealed copy must land in the password category")
    expect(secretEntry.isSecret, "a concealed copy must be flagged secret")
    expect(
        !secretEntry.previewText.contains("hmenc"),
        "a secret must never render its stored value, not even the ciphertext"
    )
    expect(
        !secretEntry.matches(query: "hmenc"),
        "search must not reach a secret's stored value"
    )

    // Export must drop secrets; persistence must keep them.
    secretStore.addSeedEntries([secretEntry])
    expect(secretStore.entries.contains(where: { $0.isSecret }), "the store keeps the secret in memory")
    expect(
        !secretStore.snapshot().entries.contains(where: { $0.isSecret }),
        "ZIP export must never carry password entries off this Mac"
    )

    // A desktop note is always visible and has no gate, so a secret must never
    // become one.
    secretStore.toggleDesktopPinned(id: secretEntry.id)
    expect(
        secretStore.entries.first(where: { $0.id == secretEntry.id })?.isDesktopPinned != true,
        "a secret must never be pinnable to the desktop — that would bypass the PIN gate"
    )

    // An identical plain copy shares the hash (it is taken over the plaintext),
    // so dedup must not collapse the two and leave the readable one behind.
    let plainTwin = ClipboardEntry(kind: .text, text: "twin", contentHash: "hash-secret")
    secretStore.addSeedEntries([plainTwin])
    expect(
        secretStore.entries.contains(where: { $0.isSecret })
            && secretStore.entries.contains(where: { $0.id == plainTwin.id }),
        "a secret and a same-hash plain entry must survive as two separate entries"
    )

    // Editing must not overwrite ciphertext with plain text.
    secretStore.updateText(id: secretEntry.id, text: "plain")
    expect(
        secretStore.entries.first(where: { $0.id == secretEntry.id })?.text == "hmenc.v1:ZmFrZQ==",
        "editing must leave a secret's ciphertext untouched"
    )

    // Lock policy.
    var lockSettings = AppLockSettings(timing: .idle5)
    expect(
        lockSettings.isCategoryLocked(.builtin(.password)),
        "the password category is locked by default"
    )
    expect(!lockSettings.isCategoryLocked(.builtin(.text)), "other categories stay unlocked by default")
    let now = Date()
    expect(
        AppLockPolicy.remainsUnlocked(settings: lockSettings, unlockedAt: now, lastUsedAt: now, now: now),
        "a fresh unlock is valid"
    )
    expect(
        !AppLockPolicy.remainsUnlocked(
            settings: lockSettings,
            unlockedAt: now.addingTimeInterval(-600),
            lastUsedAt: now.addingTimeInterval(-600),
            now: now
        ),
        "idle beyond the configured window must re-lock"
    )
    expect(
        !AppLockPolicy.remainsUnlocked(settings: lockSettings, unlockedAt: nil, lastUsedAt: nil, now: now),
        "never unlocked means locked"
    )
    var unprotected = lockSettings
    unprotected.setCategory(.builtin(.password), locked: false)
    expect(
        !unprotected.isCategoryLocked(.builtin(.password)),
        "deselecting a surface is the only thing that unlocks it — there is no master switch"
    )
    // Screen-lock-only mode has no idle timeout at all.
    lockSettings.timing = .onScreenLock
    expect(lockSettings.timing.idleInterval == nil, "screen-lock mode has no idle timeout")
    expect(
        AppLockPolicy.remainsUnlocked(
            settings: lockSettings,
            unlockedAt: now.addingTimeInterval(-86_400),
            lastUsedAt: now.addingTimeInterval(-86_400),
            now: now
        ),
        "screen-lock mode must not expire on its own"
    )
    expect(AppLockTiming.idle5.idleInterval == 300, "idle5 is five minutes")
    expect(AppLockTiming.idle15.idleInterval == 900, "idle15 is fifteen minutes")
    expect(AppLockTiming.idle30.idleInterval == 1_800, "idle30 is thirty minutes")
    expect(AppLockTiming.allCases.count == 4, "exactly the four offered timings")
    lockSettings.timing = .idle5

    lockSettings.setCategory(.builtin(.text), locked: true)
    expect(lockSettings.isCategoryLocked(.builtin(.text)), "an extra category can be locked")
    lockSettings.setCategory(.builtin(.text), locked: false)
    expect(!lockSettings.isCategoryLocked(.builtin(.text)), "and unlocked again")

    // The quick ⌘1–9 slots bypass the category UI entirely, so they must never
    // return a secret.
    let pinnedSecret = ClipboardEntry(
        kind: .text,
        text: "hmenc.v1:ZmFrZQ==",
        contentHash: "pinned-secret",
        isPinned: true,
        pinnedOrder: 0,
        origin: .concealedPassword
    )
    expect(
        ClipboardHistoryPolicy.quickEntry(in: [pinnedSecret], number: 1) == nil,
        "a pinned secret must never be reachable through a quick slot"
    )

    expect(
        !AppLockSettings().capturesPasswords,
        "password capture is off by default and requires explicit opt-in"
    )
    expect(
        !ClipboardHistorySettings().isCategoryEnabled(.builtin(.password)),
        "the password category is hidden by default until password capture is explicitly enabled"
    )
    expect(
        AppLockSettings().isCategoryLocked(.builtin(.password)),
        "…and that default is only safe because the category ships locked"
    )

    // Brute-force penalty: five wrong PINs, then a ten-minute cooldown.
    expect(AppLockPolicy.maxFailedAttempts == 5, "five attempts before the penalty")
    expect(AppLockPolicy.cooldownDuration == 600, "the penalty lasts ten minutes")
    var attempts = 0
    var cooldown: Date?
    for strike in 1...AppLockPolicy.maxFailedAttempts {
        let outcome = AppLockPolicy.afterFailedAttempt(failedAttempts: attempts, now: now)
        attempts = outcome.failedAttempts
        cooldown = outcome.cooldownUntil
        if strike < AppLockPolicy.maxFailedAttempts {
            expect(cooldown == nil, "no penalty before the fifth wrong PIN (strike \(strike))")
            expect(attempts == strike, "each wrong PIN counts once")
        }
    }
    expect(cooldown != nil, "the fifth wrong PIN starts the cooldown")
    expect(
        attempts == 0,
        "the counter resets with the penalty, so the next one needs five fresh failures"
    )
    expect(
        AppLockPolicy.isCoolingDown(until: cooldown, now: now),
        "entry is refused while the penalty runs"
    )
    expect(
        AppLockPolicy.cooldownRemaining(until: cooldown, now: now) == 600,
        "the full ten minutes remain at the start"
    )
    expect(
        !AppLockPolicy.isCoolingDown(until: cooldown, now: now.addingTimeInterval(601)),
        "entry is allowed again once it expires"
    )
    expect(
        AppLockPolicy.cooldownRemaining(until: cooldown, now: now.addingTimeInterval(900)) == 0,
        "remaining time never goes negative"
    )
    expect(
        !AppLockPolicy.isCoolingDown(until: nil, now: now),
        "no penalty means no refusal"
    )

    // The cipher envelope must be recognisable and must not be plain text.
    expect(SecretVault.isEncrypted("hmenc.v1:abc"), "the cipher envelope is detectable")
    expect(!SecretVault.isEncrypted("hunter2"), "plain text is not mistaken for ciphertext")

    // The meme panel is lockable through a reserved key that can never be
    // mistaken for a clipboard category.
    expect(
        ClipboardCategoryKey(storageValue: AppLockSettings.memePanelStorageKey) == nil,
        "the meme panel key must not parse as a clipboard category"
    )
    var panelSettings = AppLockSettings(lockedCategoryKeys: [])
    expect(!panelSettings.locksMemePanel, "the meme panel starts unlocked")
    panelSettings.setMemePanelLocked(true)
    expect(panelSettings.locksMemePanel, "the meme panel can be locked")
    expect(
        !panelSettings.isCategoryLocked(.builtin(.text)),
        "locking the meme panel must not lock a clipboard category"
    )
    panelSettings.setMemePanelLocked(false)
    expect(!panelSettings.locksMemePanel, "and unlocked again")

    // Duplicate lock targets must collapse rather than accumulate.
    var duplicated = AppLockSettings(
        lockedCategoryKeys: ["password", "password", AppLockSettings.memePanelStorageKey]
    )
    duplicated.normalize()
    expect(duplicated.lockedCategoryKeys.count == 2, "normalize de-duplicates lock targets")
}

print("HedgeMemo whitebox checks passed (\(assertionCount) assertions).")
