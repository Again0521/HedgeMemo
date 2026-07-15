import AppKit
import Combine
import Foundation

@MainActor
public final class MemeStore: ObservableObject {
    @Published public private(set) var categories: [MemeCategory] = []
    @Published public private(set) var memes: [MemeItem] = []
    @Published public var selectedCategoryID: UUID?
    @Published public var captureEnabled = false
    @Published public private(set) var lastError: String?

    public let repository: MemeRepository

    public init(repository: MemeRepository = .default) {
        self.repository = repository
        do {
            let snapshot = try repository.load()
            categories = snapshot.categories.sorted { $0.createdAt < $1.createdAt }
            memes = snapshot.memes
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func filteredMemes(query: String) -> [MemeItem] {
        MemeFilter.apply(memes, categoryID: selectedCategoryID, query: query)
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
        do {
            guard let pngData = image.pngData else { throw MemeRepositoryError.cannotEncodeImage }
            let tempStored = try repository.saveImageData(pngData)
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

    public func reorder(draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = memes.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = memes.firstIndex(where: { $0.id == targetID }) else { return }
        let categoryID = memes[targetIndex].categoryID
        guard memes[draggedIndex].categoryID == categoryID else { return }
        let item = memes.remove(at: draggedIndex)
        let destination = memes.firstIndex(where: { $0.id == targetID }) ?? memes.endIndex
        memes.insert(item, at: destination)
        normalizeSortOrders()
        persist()
    }

    public func copyToPasteboard(_ meme: MemeItem) {
        guard let image = NSImage(contentsOf: repository.imageURL(for: meme)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    public func imageURL(for meme: MemeItem) -> URL { repository.imageURL(for: meme) }

    public func clearError() { lastError = nil }

    public func report(_ error: Error) { lastError = error.localizedDescription }

    public func snapshot() -> MemeSnapshot { MemeSnapshot(categories: categories, memes: memes) }

    public func importArchive(_ manifest: MemeArchiveManifest, imagesURL: URL) {
        var categoryMap = [UUID: UUID]()
        for category in manifest.snapshot.categories {
            if let existing = categories.first(where: { $0.name == category.name }) {
                categoryMap[category.id] = existing.id
            } else if let id = addCategory(name: category.name) {
                categoryMap[category.id] = id
            }
        }
        for meme in manifest.snapshot.memes {
            let url = imagesURL.appendingPathComponent(meme.fileName)
            guard let image = NSImage(contentsOf: url) else { continue }
            _ = addImage(
                image,
                categoryID: meme.categoryID.flatMap { categoryMap[$0] },
                note: meme.note,
                ocrText: meme.ocrText
            )
        }
    }

    private func normalizeSortOrders() {
        let grouped = Dictionary(grouping: memes.indices, by: { memes[$0].categoryID })
        for (_, indices) in grouped {
            let ordered = indices.sorted { memes[$0].sortOrder < memes[$1].sortOrder }
            for (order, index) in ordered.enumerated() { memes[index].sortOrder = order }
        }
    }

    private func persist() {
        do { try repository.save(snapshot()) }
        catch { lastError = error.localizedDescription }
    }
}
