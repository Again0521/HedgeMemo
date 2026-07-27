import AppKit
import Combine
import Foundation

@MainActor
public final class MemeStore: ObservableObject {
    @Published public private(set) var categories: [MemeCategory] = []
    @Published public private(set) var memes: [MemeItem] = [] {
        didSet { filteredMemo.removeAll(keepingCapacity: true) }
    }
    @Published public var selectedCategoryID: UUID?
    /// `filteredMemes` re-filtered and re-sorted the library on every access —
    /// several times per popover render and once per mouse-move during a drag.
    /// Memoized per (category, query) until the library changes.
    private var filteredMemo: [String: [MemeItem]] = [:]
    @Published public var captureEnabled = false
    @Published public private(set) var lastError: String?

    public let repository: MemeRepository

    public init(repository: MemeRepository = .default) {
        self.repository = repository
        do {
            let snapshot = try repository.load()
            categories = snapshot.categories.sorted { $0.createdAt < $1.createdAt }
            // Array order is the source of truth for sorting; align it to the
            // persisted sortOrder so a fresh launch matches the last arrangement.
            memes = snapshot.memes.sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder { return lhs.createdAt < rhs.createdAt }
                return lhs.sortOrder < rhs.sortOrder
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func filteredMemes(query: String) -> [MemeItem] {
        let canonicalQuery = PercentFuzzyMatcher(query: query).cacheKey
        let memoKey = (selectedCategoryID?.uuidString ?? "*") + "\u{1}" + canonicalQuery
        if let cached = filteredMemo[memoKey] { return cached }
        let result = HedgeMemoPerformance.measure("MemeFiltering") {
            MemeFilter.apply(memes, categoryID: selectedCategoryID, query: canonicalQuery)
        }
        if filteredMemo.count >= 24 { filteredMemo.removeAll(keepingCapacity: true) }
        filteredMemo[memoKey] = result
        return result
    }

    @discardableResult
    public func addCategory(name: String) -> UUID? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !categories.contains(where: { $0.name == cleaned }) else { return nil }
        let category = MemeCategory(name: cleaned)
        categories.append(category)
        persist()
        return category.id
    }

    public func renameCategory(id: UUID, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !categories.contains(where: { $0.id != id && $0.name == cleaned }),
              let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].name = cleaned
        persist()
    }

    public func deleteCategory(id: UUID) {
        categories.removeAll { $0.id == id }
        for index in memes.indices where memes[index].categoryID == id {
            memes[index].categoryID = nil
            memes[index].updatedAt = .now
        }
        if selectedCategoryID == id { selectedCategoryID = nil }
        normalizeSortOrders()
        persist()
    }

    @discardableResult
    public func addImage(_ image: NSImage, categoryID: UUID? = nil, note: String? = nil, ocrText: String = "") -> Bool {
        guard let pngData = image.pngData else {
            lastError = MemeRepositoryError.cannotEncodeImage.localizedDescription
            return false
        }
        return addImageData(
            ImageAssetData(data: pngData, fileExtension: "png"),
            categoryID: categoryID,
            note: note,
            ocrText: ocrText
        )
    }

    @discardableResult
    public func addImageData(
        _ payload: ImageAssetData,
        categoryID: UUID? = nil,
        note: String? = nil,
        ocrText: String = ""
    ) -> Bool {
        do {
            guard ImageAssetData.isValidImageData(payload.data) else {
                throw MemeRepositoryError.cannotEncodeImage
            }
            // Check the hash before touching the filesystem. Repeated clipboard
            // captures no longer write and then delete a complete temporary file.
            let contentHash = payload.data.clipboardContentHash
            guard !memes.contains(where: { $0.contentHash == contentHash }) else { return false }
            let stored = try repository.saveImageData(
                payload.data,
                fileExtension: payload.fileExtension,
                precomputedContentHash: contentHash
            )
            let targetCategory = categoryID ?? selectedCategoryID
            let nextOrder = (memes.filter { $0.categoryID == targetCategory }.map(\.sortOrder).max() ?? -1) + 1
            memes.append(MemeItem(
                fileName: stored.fileName,
                contentHash: stored.contentHash,
                note: resolvedNote(note, ocrText: ocrText),
                ocrText: ocrText,
                categoryID: targetCategory,
                sortOrder: nextOrder
            ))
            persist()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func updateNote(id: UUID, note: String) {
        guard let index = memes.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        memes[index].note = cleaned.isEmpty ? (memes[index].ocrText.isEmpty ? L10n.text("未命名") : memes[index].ocrText) : cleaned
        memes[index].updatedAt = .now
        persist()
    }

    public func delete(ids: Set<UUID>) {
        let removed = memes.filter { ids.contains($0.id) }
        for meme in removed {
            do { try repository.removeImage(named: meme.fileName) }
            catch { lastError = error.localizedDescription }
        }
        memes.removeAll { ids.contains($0.id) }
        normalizeSortOrders()
        persist()
    }

    public func move(ids: Set<UUID>, to categoryID: UUID?) {
        for index in memes.indices where ids.contains(memes[index].id) {
            memes[index].categoryID = categoryID
            memes[index].updatedAt = .now
        }
        normalizeSortOrders()
        persist()
    }

    /// Live drag reordering: the dragged meme takes the target's current slot
    /// and the target shifts toward the dragged meme's old position. When the
    /// target sits in another category — dragging inside “全部” — the dragged
    /// meme adopts that category, so a drop always lands exactly where it
    /// points. (The previous guard silently rejected cross-category targets,
    /// which is why releasing a drag in “全部” often did nothing.)
    public func reorder(draggedID: UUID, over targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = memes.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = memes.firstIndex(where: { $0.id == targetID }) else { return }
        var item = memes[draggedIndex]
        if item.categoryID != memes[targetIndex].categoryID {
            item.categoryID = memes[targetIndex].categoryID
            item.updatedAt = .now
        }
        memes.remove(at: draggedIndex)
        // Inserting at the target's pre-removal index puts the dragged meme in
        // the target's former slot for drags in either direction.
        memes.insert(item, at: targetIndex)
        normalizeSortOrders()
        persist()
    }

    /// Moves the dragged meme to the tail of `categoryID`, adopting that
    /// category. A nil category means the “全部” view: keep the meme's own
    /// category and move it to the very end of the list.
    public func reorderToEnd(draggedID: UUID, categoryID: UUID?) {
        guard let draggedIndex = memes.firstIndex(where: { $0.id == draggedID }) else { return }
        var item = memes[draggedIndex]
        let destinationCategory = categoryID ?? item.categoryID
        if item.categoryID != destinationCategory {
            item.categoryID = destinationCategory
            item.updatedAt = .now
        }
        memes.remove(at: draggedIndex)
        let destination = categoryID == nil
            ? memes.endIndex
            : memes.lastIndex(where: { $0.categoryID == destinationCategory }).map { $0 + 1 } ?? memes.endIndex
        memes.insert(item, at: destination)
        normalizeSortOrders()
        persist()
    }

    /// Invoked right after a meme is written to the system pasteboard, so the
    /// owner can keep that write out of the app's own clipboard history — a
    /// pasted meme should reach the next app, not pile up in the clipboard list.
    public var onDidCopyToPasteboard: (@MainActor () -> Void)?

    public func copyToPasteboard(_ meme: MemeItem, to pasteboard: NSPasteboard = .general) {
        guard let payload = ImageAssetData(fileURL: repository.imageURL(for: meme)) else { return }
        guard payload.write(to: pasteboard) else { return }
        onDidCopyToPasteboard?()
    }

    public func imageURL(for meme: MemeItem) -> URL { repository.imageURL(for: meme) }

    public func clearError() { lastError = nil }

    /// Search results can each contain the whole library. The popover is an
    /// ephemeral surface, so discard these arrays once it closes.
    public func releaseTransientCaches() {
        filteredMemo.removeAll(keepingCapacity: false)
    }

    public func report(_ error: Error) { lastError = error.localizedDescription }

    public func snapshot() -> MemeSnapshot { MemeSnapshot(categories: categories, memes: memes) }

    public func importArchive(_ manifest: MemeArchiveManifest, imagesURL: URL) {
        guard let memeSnapshot = manifest.memeSnapshot else { return }

        // Build the import in local values and publish once. The former loop
        // called addCategory/addImageData per item, re-encoding the complete
        // library JSON and invalidating the grid after every single image.
        var categoryMap = [UUID: UUID]()
        var categoryIDsByName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0.id) })
        var importedCategories: [MemeCategory] = []
        for category in memeSnapshot.categories {
            let cleaned = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if let existingID = categoryIDsByName[cleaned] {
                categoryMap[category.id] = existingID
            } else {
                let imported = MemeCategory(name: cleaned)
                importedCategories.append(imported)
                categoryIDsByName[cleaned] = imported.id
                categoryMap[category.id] = imported.id
            }
        }

        var knownHashes = Set(memes.map(\.contentHash))
        var nextOrderByCategory: [UUID?: Int] = [:]
        for meme in memes {
            nextOrderByCategory[meme.categoryID] = max(
                nextOrderByCategory[meme.categoryID] ?? 0,
                meme.sortOrder + 1
            )
        }
        var importedMemes: [MemeItem] = []
        for meme in memeSnapshot.memes {
            guard let url = MemeArchiveService.safeContainedURL(base: imagesURL, fileName: meme.fileName),
                  let payload = ImageAssetData(fileURL: url) else { continue }
            let contentHash = payload.data.clipboardContentHash
            guard knownHashes.insert(contentHash).inserted else { continue }
            do {
                let stored = try repository.saveImageData(
                    payload.data,
                    fileExtension: payload.fileExtension,
                    precomputedContentHash: contentHash
                )
                // Preserve addImageData's existing nil-category behavior: an
                // uncategorized archive item enters the currently selected group.
                let targetCategory = meme.categoryID.flatMap { categoryMap[$0] } ?? selectedCategoryID
                let sortOrder = nextOrderByCategory[targetCategory] ?? 0
                nextOrderByCategory[targetCategory] = sortOrder + 1
                importedMemes.append(MemeItem(
                    fileName: stored.fileName,
                    contentHash: stored.contentHash,
                    note: resolvedNote(meme.note, ocrText: meme.ocrText),
                    ocrText: meme.ocrText,
                    categoryID: targetCategory,
                    sortOrder: sortOrder
                ))
            } catch {
                // A failed write must not reserve the hash: another archive entry
                // with the same bytes may still be importable.
                knownHashes.remove(contentHash)
                lastError = error.localizedDescription
            }
        }

        guard !importedCategories.isEmpty || !importedMemes.isEmpty else { return }
        if !importedCategories.isEmpty {
            categories.append(contentsOf: importedCategories)
        }
        if !importedMemes.isEmpty {
            memes.append(contentsOf: importedMemes)
        }
        persist()
    }

    private func resolvedNote(_ note: String?, ocrText: String) -> String {
        let displayNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayNote, !displayNote.isEmpty { return displayNote }
        let generatedNote = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return generatedNote.isEmpty ? L10n.text("未命名") : generatedNote
    }

    /// Assigns `sortOrder` from each item's position in `memes`, making the array
    /// order the single source of truth. `reorder` moves items within the array,
    /// so deriving order from stale `sortOrder` here would silently undo the drag.
    private func normalizeSortOrders() {
        var nextOrder = [UUID?: Int]()
        for index in memes.indices {
            let category = memes[index].categoryID
            let order = nextOrder[category, default: 0]
            memes[index].sortOrder = order
            nextOrder[category] = order + 1
        }
    }

    private func persist() {
        repository.saveAsync(snapshot()) { [weak self] errorMessage in
            guard let errorMessage else { return }
            Task { @MainActor [weak self] in
                self?.lastError = errorMessage
            }
        }
    }

    /// Durability barrier for application termination and deterministic tests.
    public func flushPendingSave() {
        repository.flushSnapshotWrites()
    }
}
