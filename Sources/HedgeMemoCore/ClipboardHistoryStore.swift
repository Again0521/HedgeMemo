import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
public final class ClipboardHistoryStore: ObservableObject {
    @Published public private(set) var entries: [ClipboardEntry] = [] {
        didSet { orderedMemo.removeAll(keepingCapacity: true) }
    }
    /// `orderedEntries` is asked several times per UI pass (rows, key handling,
    /// height math), and every miss filters and sorts the entire history.
    /// Results are memoized per (category, query) until entries or settings
    /// change. Not published: reads during view rendering must stay silent.
    private var orderedMemo: [String: [ClipboardEntry]] = [:]
    // Mutating `settings` inside its own didSet re-enters the @Published setter;
    // without this guard normalize() recurses until the stack overflows.
    private var isNormalizingSettings = false
    @Published public var settings: ClipboardHistorySettings {
        didSet {
            // Category enable/order/custom-pattern changes all affect ordering.
            orderedMemo.removeAll(keepingCapacity: true)
            guard !isNormalizingSettings else { return }
            isNormalizingSettings = true
            settings.normalize()
            isNormalizingSettings = false
            trimToLimit()
            persist()
        }
    }
    @Published public private(set) var lastError: String?
    /// While the meme library is capturing clipboard images, history recording is
    /// paused so the captured content doesn't also pile up in the clipboard list.
    public var isRecordingPaused = false

    public let repository: ClipboardHistoryRepository

    private var timer: Timer?
    private var observedChangeCount = NSPasteboard.general.changeCount
    private var suppressedChangeCount: Int?
    /// Sleep/wake observers so the poll can be torn down while nothing can copy.
    private var sleepWakeObservers: [NSObjectProtocol] = []
    /// True between `startMonitoring()` and `stopMonitoring()`. Distinguishes a
    /// deliberate stop from a sleep-induced suspend so the timer only rebuilds
    /// on wake when monitoring is actually meant to be running.
    private var isMonitoringEnabled = false

    public init(repository: ClipboardHistoryRepository = .default) {
        self.repository = repository
        do {
            let snapshot = try repository.load()
            entries = snapshot.entries
            settings = snapshot.settings
        } catch {
            entries = []
            settings = ClipboardHistorySettings()
            lastError = error.localizedDescription
        }
        let removedDuplicates = collapsePersistedDuplicates()
        if removedDuplicates || normalizeDesktopPinnedOrders() { persist() }
    }

    public func startMonitoring() {
        stopMonitoring()
        isMonitoringEnabled = true
        observedChangeCount = NSPasteboard.general.changeCount
        schedulePollTimer()
        installSleepWakeObservers()
    }

    public func stopMonitoring() {
        isMonitoringEnabled = false
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers { center.removeObserver(observer) }
        sleepWakeObservers.removeAll()
    }

    private func schedulePollTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            // A RunLoop timer is delivered on the main thread, but its closure
            // is not actor-isolated. Hop explicitly instead of using
            // `assumeIsolated`, whose runtime assertion can crash while AppKit
            // is processing another event.
            Task { @MainActor [weak self] in
                self?.inspectPasteboard()
            }
        }
        // This poll runs for the whole session in the background. A generous
        // tolerance lets the OS coalesce its wakeups with other timers, which
        // cuts idle energy/CPU use noticeably; a copy is still picked up within
        // roughly a second, which is imperceptible for a clipboard manager.
        timer.tolerance = 0.25
        // `.default` mode matches the previous `scheduledTimer` behavior exactly
        // (it pauses only during menu/event tracking); the sole change here is
        // the added tolerance.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    /// Nothing can be copied while the display is asleep or the machine is
    /// suspended, so tear the poll timer down for those windows and rebuild it
    /// on wake. Over a locked-and-away laptop this removes one to two CPU
    /// wakeups per second for hours; on wake the change-count comparison still
    /// captures whatever was last on the pasteboard.
    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepNames: [NSNotification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ]
        let wakeNames: [NSNotification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in sleepNames {
            sleepWakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendPolling() }
            })
        }
        for name in wakeNames {
            sleepWakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumePollingIfNeeded() }
            })
        }
    }

    private func suspendPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func resumePollingIfNeeded() {
        guard isMonitoringEnabled, timer == nil else { return }
        schedulePollTimer()
    }

    public func orderedEntries(query: String = "", key: ClipboardCategoryKey? = nil) -> [ClipboardEntry] {
        if let key, !settings.isCategoryEnabled(key) { return [] }
        let memoKey = (key?.storageValue ?? "*") + "\u{1}" + query
        if let cached = orderedMemo[memoKey] { return cached }
        let result = ClipboardHistoryPolicy.ordered(
            entries,
            query: query,
            key: key,
            customCategories: settings.customCategories ?? []
        )
        // Typing a search accumulates one memo entry per query string; keep the
        // table small rather than tracking usage.
        if orderedMemo.count >= 24 { orderedMemo.removeAll(keepingCapacity: true) }
        orderedMemo[memoKey] = result
        return result
    }

    @discardableResult
    public func addText(_ text: String, sourceApp: String? = nil) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let hash = Data(cleaned.utf8).clipboardContentHash
        let entry = ClipboardEntry(kind: .text, text: text, contentHash: hash, sourceApp: sourceApp)
        guard shouldRecord(entry) else { return false }
        if promoteExistingEntry(contentHash: hash, sourceApp: sourceApp) {
            persist()
            return false
        }
        entries.append(entry)
        trimToLimit()
        persist()
        return true
    }

    @discardableResult
    public func addImage(
        _ image: NSImage,
        note: String? = nil,
        sourceApp: String? = nil,
        origin: ClipboardEntryOrigin? = nil
    ) -> Bool {
        guard let data = image.pngData else { return false }
        return addImageData(ImageAssetData(data: data, fileExtension: "png"), note: note, sourceApp: sourceApp, origin: origin)
    }

    @discardableResult
    public func addImageData(
        _ payload: ImageAssetData,
        note: String? = nil,
        sourceApp: String? = nil,
        origin: ClipboardEntryOrigin? = nil
    ) -> Bool {
        guard settings.savesImages else { return false }
        do {
            let candidate = ClipboardEntry(
                kind: .image,
                text: note,
                contentHash: payload.data.clipboardContentHash,
                sourceApp: sourceApp,
                origin: origin
            )
            guard shouldRecord(candidate) else { return false }
            if promoteExistingEntry(contentHash: candidate.contentHash, sourceApp: sourceApp) {
                persist()
                return false
            }
            let stored = try repository.saveImageData(payload.data, fileExtension: payload.fileExtension)
            entries.append(ClipboardEntry(
                kind: .image,
                text: note,
                imageFileName: stored.fileName,
                contentHash: stored.contentHash,
                sourceApp: sourceApp,
                origin: origin
            ))
            trimToLimit()
            persist()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Records images created by HedgeMemo's screenshot flow separately from
    /// images copied by other apps, then consumes the pasteboard change so the
    /// monitor cannot add a duplicate to the generic 图片 category.
    @discardableResult
    public func recordScreenshot(_ payload: ImageAssetData) -> Bool {
        let changeCount = NSPasteboard.general.changeCount
        observedChangeCount = changeCount
        suppressedChangeCount = changeCount
        return addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot)
    }

    /// Marks the pasteboard's current change as one the app made itself (e.g. a
    /// meme click that puts an image on the system clipboard to paste). The next
    /// poll then treats it as already handled instead of recording it back into
    /// the history, so pasting a meme never pollutes the clipboard list. Call
    /// this immediately after the app's own pasteboard write.
    public func suppressCurrentPasteboardChange() {
        let changeCount = NSPasteboard.general.changeCount
        observedChangeCount = changeCount
        suppressedChangeCount = changeCount
    }

    public func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        removeImageIfNeeded(removed)
        normalizePinOrders()
        persist()
    }

    public func clearHistory() {
        let removed = entries
        entries.removeAll()
        for entry in removed { removeImageIfNeeded(entry) }
        persist()
    }

    /// Number of unique entries covered by a set of categories. Custom regex
    /// categories may overlap built-ins or one another, so entries are counted
    /// once even when several selected keys match them.
    public func entryCount(matching keys: Set<ClipboardCategoryKey>) -> Int {
        guard !keys.isEmpty else { return 0 }
        let customs = settings.customCategories ?? []
        return entries.lazy.filter { entry in
            keys.contains { entry.matches(key: $0, customCategories: customs) }
        }.count
    }

    /// Clears only entries matched by at least one selected category, including
    /// backing image files. Category configuration and enabled state are kept.
    public func clearHistory(matching keys: Set<ClipboardCategoryKey>) {
        guard !keys.isEmpty else { return }
        let customs = settings.customCategories ?? []
        let removed = entries.filter { entry in
            keys.contains { entry.matches(key: $0, customCategories: customs) }
        }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        entries.removeAll { removedIDs.contains($0.id) }
        for entry in removed { removeImageIfNeeded(entry) }
        normalizePinOrders()
        persist()
    }

    public func snapshot() -> ClipboardHistorySnapshot {
        ClipboardHistorySnapshot(entries: entries, settings: settings)
    }

    /// Appends first-run guidance entries the caller has already ordered and
    /// timestamped, then persists. Only first-install seeding uses this; it is
    /// deliberately separate from `addText`, which timestamps with `.now` and
    /// merges consecutive duplicates.
    public func addSeedEntries(_ seedEntries: [ClipboardEntry]) {
        guard !seedEntries.isEmpty else { return }
        entries.append(contentsOf: seedEntries)
        _ = collapsePersistedDuplicates()
        trimToLimit()
        persist()
    }

    /// Archive import deliberately reuses the ordinary storage path so imported
    /// image assets are re-hashed and never overwrite an existing clipboard file.
    public func importArchive(_ snapshot: ClipboardHistorySnapshot, imagesURL: URL) {
        for entry in snapshot.entries {
            switch entry.kind {
            case .text:
                _ = addText(entry.text ?? "", sourceApp: entry.sourceApp)
            case .image:
                guard let fileName = entry.imageFileName,
                      let payload = ImageAssetData(fileURL: imagesURL.appendingPathComponent(fileName)) else { continue }
                _ = addImageData(payload, note: entry.text, sourceApp: entry.sourceApp, origin: entry.origin)
            }
        }
    }

    /// Disabling a category is destructive by design: its current entries are
    /// removed from disk and it will no longer collect matching clipboard data.
    public func setCategory(_ key: ClipboardCategoryKey, enabled: Bool) {
        guard settings.isCategoryEnabled(key) != enabled else { return }
        if !enabled { clearEntries(matching: key) }
        settings.setCategory(key, enabled: enabled)
        if !settings.isCategoryEnabled(settings.activeCategoryKey) {
            settings.activeCategoryKey = settings.enabledCategoryKeys.first ?? .builtin(.text)
        }
    }

    public func togglePinned(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].isPinned {
            entries[index].isPinned = false
            entries[index].pinnedOrder = nil
        } else {
            let nextOrder = (entries.compactMap(\.pinnedOrder).max() ?? -1) + 1
            entries[index].isPinned = true
            entries[index].pinnedOrder = nextOrder
        }
        entries[index].updatedAt = .now
        normalizePinOrders()
        persist()
    }

    public func toggleDesktopPinned(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].isDesktopPinned == true {
            entries[index].isDesktopPinned = false
            entries[index].desktopPinnedOrder = nil
        } else {
            let nextOrder = (entries.compactMap(\.desktopPinnedOrder).max() ?? -1) + 1
            entries[index].isDesktopPinned = true
            entries[index].desktopPinnedOrder = nextOrder
        }
        entries[index].updatedAt = .now
        _ = normalizeDesktopPinnedOrders()
        persist()
    }

    /// Applies an in-place edit to a text-kind entry's content. The content
    /// hash is recomputed so later dedup/merge checks see the edited text, not
    /// the one originally captured. Image entries are left untouched — they
    /// have no editable text body.
    public func updateText(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .text else { return }
        entries[index].text = text
        entries[index].contentHash = Data(text.utf8).clipboardContentHash
        entries[index].updatedAt = .now
        _ = collapsePersistedDuplicates()
        persist()
    }

    @discardableResult
    public func copyToPasteboard(_ entry: ClipboardEntry, autoPaste: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case .text:
            guard let text = entry.text else { return false }
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let url = repository.imageURL(for: entry),
                  let payload = ImageAssetData(fileURL: url) else { return false }
            payload.write(to: pasteboard)
        }
        suppressedChangeCount = pasteboard.changeCount
        observedChangeCount = pasteboard.changeCount
        markUsed(id: entry.id)
        if autoPaste { pasteIntoFocusedAppIfAllowed() }
        return true
    }

    private func markUsed(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastUsedAt = .now
        entries[index].useCount = (entries[index].useCount ?? 0) + 1
        persist()
    }

    /// Re-copying content already held by HedgeMemo is a recency update, not a
    /// new history item. Explicit pin states remain intact; ordinary items move
    /// forward through the same creation-time ordering as a newly captured item.
    @discardableResult
    private func promoteExistingEntry(
        contentHash: String,
        sourceApp: String?,
        now: Date = .now
    ) -> Bool {
        let matches = entries.filter { $0.contentHash == contentHash }
        guard !matches.isEmpty else { return false }
        var merged = mergedEntry(from: matches)
        merged.createdAt = now
        merged.updatedAt = now
        if let sourceApp { merged.sourceApp = sourceApp }
        replaceEntries(matching: contentHash, with: merged)
        normalizePinOrders()
        _ = normalizeDesktopPinnedOrders()
        return true
    }

    /// Older snapshots can already contain non-consecutive duplicates. Collapse
    /// them once on load (and after edit/seed paths) without changing recency.
    @discardableResult
    private func collapsePersistedDuplicates() -> Bool {
        let duplicateHashes = Dictionary(grouping: entries, by: \.contentHash)
            .filter { $0.value.count > 1 }
        guard !duplicateHashes.isEmpty else { return false }
        for (hash, matches) in duplicateHashes {
            replaceEntries(matching: hash, with: mergedEntry(from: matches))
        }
        normalizePinOrders()
        _ = normalizeDesktopPinnedOrders()
        return true
    }

    private func mergedEntry(from matches: [ClipboardEntry]) -> ClipboardEntry {
        precondition(!matches.isEmpty)
        var merged = matches.max { $0.createdAt < $1.createdAt }!
        let pinned = matches.filter(\.isPinned)
        let desktopPinned = matches.filter { $0.isDesktopPinned == true }
        merged.isPinned = !pinned.isEmpty
        merged.pinnedOrder = pinned.compactMap(\.pinnedOrder).min()
        merged.isDesktopPinned = !desktopPinned.isEmpty
        merged.desktopPinnedOrder = desktopPinned.compactMap(\.desktopPinnedOrder).min()
        merged.lastUsedAt = matches.compactMap(\.lastUsedAt).max()
        let totalUseCount = matches.compactMap(\.useCount).reduce(0, +)
        merged.useCount = totalUseCount == 0 ? nil : totalUseCount
        return merged
    }

    private func replaceEntries(matching contentHash: String, with merged: ClipboardEntry) {
        let removed = entries.filter { $0.contentHash == contentHash && $0.id != merged.id }
        for entry in removed where entry.kind == .image {
            guard let fileName = entry.imageFileName,
                  fileName != merged.imageFileName else { continue }
            try? repository.removeImage(named: fileName)
        }
        entries.removeAll { $0.contentHash == contentHash }
        entries.append(merged)
    }

    @discardableResult
    public func copyPinned(number: Int, autoPaste: Bool = false) -> Bool {
        guard let entry = ClipboardHistoryPolicy.quickEntry(in: entries, number: number) else { return false }
        return copyToPasteboard(entry, autoPaste: autoPaste)
    }

    public func imageURL(for entry: ClipboardEntry) -> URL? { repository.imageURL(for: entry) }

    public func clearError() { lastError = nil }

    /// Search/category results are presentation caches, not user data. Drop them
    /// when the clipboard panel closes so a large history does not keep several
    /// full filtered arrays alive while the app is idle.
    public func releaseTransientCaches() {
        orderedMemo.removeAll(keepingCapacity: false)
    }

    /// Preview/self-check only: swap the in-memory list without touching the
    /// persisted history, so UI stress flows can run against dense fake data.
    /// Persistence is disabled from this point on for the whole process —
    /// otherwise any later mutation (a settings change, a clipboard event)
    /// would overwrite the user's real history with the fakes.
    public func injectPreviewEntries(_ previewEntries: [ClipboardEntry]) {
        isPersistenceDisabled = true
        entries = previewEntries
    }

    private var isPersistenceDisabled = false

    /// Internal (not private) so a `@testable` integration test can drive one
    /// poll deterministically instead of waiting on the real timer.
    func inspectPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        if suppressedChangeCount == pasteboard.changeCount {
            suppressedChangeCount = nil
            return
        }
        // Keep observedChangeCount current (done above) so resuming won't capture
        // whatever was copied while the meme library was grabbing images.
        guard !isRecordingPaused else { return }
        // The copy happened within the last polling interval, so the frontmost
        // app is a good approximation of where the content came from.
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        // Require an explicitly declared text payload. Asking AppKit to convert
        // a Finder file URL to `.string` can resolve the external file and cause
        // a broad Documents permission prompt during background monitoring.
        if pasteboard.types?.contains(.string) == true,
           let text = pasteboard.string(forType: .string),
           addText(text, sourceApp: sourceApp) { return }
        if settings.savesImages, let image = ImageAssetData.read(from: pasteboard, allowFileURLs: false) {
            _ = addImageData(image, sourceApp: sourceApp)
        }
    }

    private func shouldRecord(_ entry: ClipboardEntry) -> Bool {
        guard settings.isCategoryEnabled(.builtin(entry.contentCategory)) else { return false }
        for custom in settings.customCategories ?? [] {
            let key = ClipboardCategoryKey.custom(custom.id)
            if !settings.isCategoryEnabled(key), entry.matches(key: key, customCategories: [custom]) {
                return false
            }
        }
        return true
    }

    private func clearEntries(matching key: ClipboardCategoryKey) {
        let customs = settings.customCategories ?? []
        let removed = entries.filter { $0.matches(key: key, customCategories: customs) }
        entries.removeAll { $0.matches(key: key, customCategories: customs) }
        for entry in removed { removeImageIfNeeded(entry) }
        normalizePinOrders()
    }

    private func trimToLimit() {
        let ids = Set(ClipboardHistoryPolicy.idsToTrim(from: entries, maxEntries: settings.maxEntries))
        guard !ids.isEmpty else { return }
        let removed = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        for entry in removed { removeImageIfNeeded(entry) }
    }

    private func normalizePinOrders() {
        let pinnedIDs = ClipboardHistoryPolicy.pinnedEntries(entries).map(\.id)
        for (order, id) in pinnedIDs.enumerated() {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            entries[index].pinnedOrder = order
        }
        _ = normalizeDesktopPinnedOrders()
    }

    /// Assigns stable order to snapshots created before desktop pin order was
    /// persisted, and compacts gaps after an unpin/delete. `updatedAt` is the
    /// best available approximation of first-pin time for legacy snapshots.
    @discardableResult
    private func normalizeDesktopPinnedOrders() -> Bool {
        let pinnedIDs = ClipboardHistoryPolicy.desktopPinnedEntries(entries).map(\.id)
        var changed = false
        for (order, id) in pinnedIDs.enumerated() {
            guard let index = entries.firstIndex(where: { $0.id == id }),
                  entries[index].desktopPinnedOrder != order else { continue }
            entries[index].desktopPinnedOrder = order
            changed = true
        }
        return changed
    }

    private func removeImageIfNeeded(_ entry: ClipboardEntry) {
        guard let fileName = entry.imageFileName else { return }
        do { try repository.removeImage(named: fileName) }
        catch { lastError = error.localizedDescription }
    }

    private func persist() {
        guard !isPersistenceDisabled else { return }
        do {
            try repository.save(ClipboardHistorySnapshot(entries: entries, settings: settings))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pasteIntoFocusedAppIfAllowed() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
