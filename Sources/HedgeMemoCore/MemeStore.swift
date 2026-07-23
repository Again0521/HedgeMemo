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
        let memoKey = (selectedCategoryID?.uuidString ?? "*") + "\u{1}" + query
        if let cached = filteredMemo[memoKey] { return cached }
        let result = MemeFilter.apply(memes, categoryID: selectedCategoryID, query: query)
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
            guard NSImage(data: payload.data) != nil else { throw MemeRepositoryError.cannotEncodeImage }
            let tempStored = try repository.saveImageData(payload.data, fileExtension: payload.fileExtension)
            guard !memes.contains(where: { $0.contentHash == tempStored.contentHash }) else {
                try repository.removeImage(named: tempStored.fileName)
                return false
            }
            let targetCategory = categoryID ?? selectedCategoryID
            let displayNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let generatedNote = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextOrder = (memes.filter { $0.categoryID == targetCategory }.map(\.sortOrder).max() ?? -1) + 1
            memes.append(MemeItem(
                fileName: tempStored.fileName,
                contentHash: tempStored.contentHash,
                note: (displayNote?.isEmpty == false ? displayNote! : (generatedNote.isEmpty ? "未命名" : generatedNote)),
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
        memes[index].note = cleaned.isEmpty ? (memes[index].ocrText.isEmpty ? "未命名" : memes[index].ocrText) : cleaned
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
        var categoryMap = [UUID: UUID]()
        for category in memeSnapshot.categories {
            if let existing = categories.first(where: { $0.name == category.name }) {
                categoryMap[category.id] = existing.id
            } else if let id = addCategory(name: category.name) {
                categoryMap[category.id] = id
            }
        }
        for meme in memeSnapshot.memes {
            let url = imagesURL.appendingPathComponent(meme.fileName)
            guard let payload = ImageAssetData(fileURL: url) else { continue }
            _ = addImageData(
                payload,
                categoryID: meme.categoryID.flatMap { categoryMap[$0] },
                note: meme.note,
                ocrText: meme.ocrText
            )
        }
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
        do { try repository.save(snapshot()) }
        catch { lastError = error.localizedDescription }
    }
}
