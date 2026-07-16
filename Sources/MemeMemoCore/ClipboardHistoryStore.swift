import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
public final class ClipboardHistoryStore: ObservableObject {
    @Published public private(set) var entries: [ClipboardEntry] = []
    // Mutating `settings` inside its own didSet re-enters the @Published setter;
    // without this guard normalize() recurses until the stack overflows.
    private var isNormalizingSettings = false
    @Published public var settings: ClipboardHistorySettings {
        didSet {
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
    }

    public func startMonitoring() {
        stopMonitoring()
        observedChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspectPasteboard() }
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func orderedEntries(query: String = "", key: ClipboardCategoryKey? = nil) -> [ClipboardEntry] {
        ClipboardHistoryPolicy.ordered(
            entries,
            query: query,
            key: key,
            customCategories: settings.customCategories ?? []
        )
    }

    @discardableResult
    public func addText(_ text: String, sourceApp: String? = nil) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let hash = Data(cleaned.utf8).clipboardContentHash
        guard !ClipboardHistoryPolicy.shouldMergeWithLatest(latest: orderedEntries().first, contentHash: hash) else { return false }
        entries.append(ClipboardEntry(kind: .text, text: text, contentHash: hash, sourceApp: sourceApp))
        trimToLimit()
        persist()
        return true
    }

    @discardableResult
    public func addImage(_ image: NSImage, note: String? = nil, sourceApp: String? = nil) -> Bool {
        guard let data = image.pngData else { return false }
        return addImageData(ImageAssetData(data: data, fileExtension: "png"), note: note, sourceApp: sourceApp)
    }

    @discardableResult
    public func addImageData(_ payload: ImageAssetData, note: String? = nil, sourceApp: String? = nil) -> Bool {
        guard settings.savesImages else { return false }
        do {
            let stored = try repository.saveImageData(payload.data, fileExtension: payload.fileExtension)
            guard !ClipboardHistoryPolicy.shouldMergeWithLatest(latest: orderedEntries().first, contentHash: stored.contentHash) else {
                try repository.removeImage(named: stored.fileName)
                return false
            }
            entries.append(ClipboardEntry(
                kind: .image,
                text: note,
                imageFileName: stored.fileName,
                contentHash: stored.contentHash,
                sourceApp: sourceApp
            ))
            trimToLimit()
            persist()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        removeImageIfNeeded(removed)
        normalizePinnedOrders()
        persist()
    }

    public func clearHistory() {
        let removed = entries
        entries.removeAll()
        for entry in removed { removeImageIfNeeded(entry) }
        persist()
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
        normalizePinnedOrders()
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

    @discardableResult
    public func copyPinned(number: Int, autoPaste: Bool = false) -> Bool {
        guard let entry = ClipboardHistoryPolicy.quickEntry(in: entries, number: number) else { return false }
        return copyToPasteboard(entry, autoPaste: autoPaste)
    }

    public func imageURL(for entry: ClipboardEntry) -> URL? { repository.imageURL(for: entry) }

    public func clearError() { lastError = nil }

    private func inspectPasteboard() {
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
        if let text = pasteboard.string(forType: .string), addText(text, sourceApp: sourceApp) { return }
        if settings.savesImages, let image = ImageAssetData.read(from: pasteboard) {
            _ = addImageData(image, sourceApp: sourceApp)
        }
    }

    private func trimToLimit() {
        let ids = Set(ClipboardHistoryPolicy.idsToTrim(from: entries, maxEntries: settings.maxEntries))
        guard !ids.isEmpty else { return }
        let removed = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        for entry in removed { removeImageIfNeeded(entry) }
    }

    private func normalizePinnedOrders() {
        let pinnedIDs = ClipboardHistoryPolicy.pinnedEntries(entries).map(\.id)
        for (order, id) in pinnedIDs.enumerated() {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            entries[index].pinnedOrder = order
        }
    }

    private func removeImageIfNeeded(_ entry: ClipboardEntry) {
        guard let fileName = entry.imageFileName else { return }
        do { try repository.removeImage(named: fileName) }
        catch { lastError = error.localizedDescription }
    }

    private func persist() {
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
