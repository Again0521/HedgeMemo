import AppKit
import Combine
import Foundation

/// A zero-materialization view over the store's canonical meme array.
///
/// SwiftUI asks the panel's `visibleMemes` computed property several times in
/// one body pass. Returning `[MemeItem]` rebuilt the whole filtered library for
/// every access even when the expensive filtering itself was memoized. This
/// collection shares both the source array and the memoized position buffer;
/// random access, iteration and ordering remain exactly the same.
public struct MemeFilteredResults: RandomAccessCollection, Sendable {
    public typealias Element = MemeItem
    public typealias Index = Int

    private let source: [MemeItem]
    private let positions: [Int]?

    init(source: [MemeItem], positions: [Int]?) {
        self.source = source
        self.positions = positions
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { positions?.count ?? source.count }

    public subscript(position: Int) -> MemeItem {
        source[positions?[position] ?? position]
    }

    /// Test/diagnostic evidence that an identity result retains no redundant
    /// integer-per-item projection. Filtered results retain only positions,
    /// never a second array of full `MemeItem` values.
    var retainedPositionCount: Int { positions?.count ?? 0 }
}

@MainActor
public final class MemeStore: ObservableObject {
    private enum FilteredProjection {
        case identity
        case positions([Int])

        var retainedPositionCount: Int {
            switch self {
            case .identity: 0
            case .positions(let positions): positions.count
            }
        }
    }

    struct ImportHashIndexMetrics: Equatable {
        let seededHashCount: Int
        let candidateHashCount: Int
        let acceptedHashCount: Int
        let peakResidentHashCount: Int
    }

    @Published public private(set) var categories: [MemeCategory] = []
    @Published public private(set) var memes: [MemeItem] = [] {
        didSet {
            filteredMemo.removeAll(keepingCapacity: true)
            filteredMemoPositionCount = 0
        }
    }
    @Published public var selectedCategoryID: UUID?
    /// `filteredMemes` re-filtered and re-sorted the library on every access —
    /// several times per popover render and once per mouse-move during a drag.
    /// Memoized per (category, query) until the library changes.
    private var filteredMemo: [String: FilteredProjection] = [:]
    private var filteredMemoPositionCount = 0
    private static let filteredMemoEntryLimit = 8
    private static let filteredMemoPositionBudget = 100_000
    /// Drag reordering can emit dozens of mutations per second. Keep the live
    /// array/UI updates immediate, but collapse their full-library snapshots
    /// into one trailing write.
    private var pendingSaveWork: DispatchWorkItem?
    @Published public var captureEnabled = false
    @Published public private(set) var lastError: String?
    private(set) var lastImportHashIndexMetrics = ImportHashIndexMetrics(
        seededHashCount: 0,
        candidateHashCount: 0,
        acceptedHashCount: 0,
        peakResidentHashCount: 0
    )

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

    public func filteredMemes(query: String) -> MemeFilteredResults {
        let canonicalQuery = PercentFuzzyMatcher(query: query).cacheKey
        let memoKey = (selectedCategoryID?.uuidString ?? "*") + "\u{1}" + canonicalQuery
        if let cached = filteredMemo[memoKey] {
            return results(for: cached)
        }
        let resultIndices = HedgeMemoPerformance.measure("MemeFiltering") {
            let matcher = PercentFuzzyMatcher(query: canonicalQuery)
            var indices = memes.indices.filter { index in
                let meme = memes[index]
                return (selectedCategoryID == nil || meme.categoryID == selectedCategoryID)
                    && (matcher.matchesEveryCandidate || meme.matches(matcher: matcher))
            }
            indices.sort { lhsIndex, rhsIndex in
                let lhs = memes[lhsIndex]
                let rhs = memes[rhsIndex]
                if lhs.sortOrder == rhs.sortOrder { return lhs.createdAt < rhs.createdAt }
                return lhs.sortOrder < rhs.sortOrder
            }
            return indices
        }
        let projection: FilteredProjection = resultIndices.elementsEqual(memes.indices)
            ? .identity
            : .positions(resultIndices)
        cache(projection, for: memoKey)
        return results(for: projection)
    }

    private func cache(_ projection: FilteredProjection, for key: String) {
        let cost = projection.retainedPositionCount
        if filteredMemo.count >= Self.filteredMemoEntryLimit
            || filteredMemoPositionCount + cost > Self.filteredMemoPositionBudget {
            // One result may itself exceed the budget. Keep that current result
            // for repeated SwiftUI reads, but never retain older full-library
            // projections beside it.
            filteredMemo.removeAll(keepingCapacity: true)
            filteredMemoPositionCount = 0
        }
        filteredMemo[key] = projection
        filteredMemoPositionCount += cost
    }

    private func results(for projection: FilteredProjection) -> MemeFilteredResults {
        switch projection {
        case .identity:
            MemeFilteredResults(source: memes, positions: nil)
        case .positions(let positions):
            MemeFilteredResults(source: memes, positions: positions)
        }
    }

    @discardableResult
    public func addCategory(name: String) -> UUID? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !categories.contains(where: { $0.name == cleaned }) else { return nil }
        let category = MemeCategory(name: cleaned)
        categories.append(category)
        persistCategoryDelta(category, appending: true)
        return category.id
    }

    public func renameCategory(id: UUID, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !categories.contains(where: { $0.id != id && $0.name == cleaned }),
              let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].name = cleaned
        persistCategoryDelta(categories[index], appending: false)
    }

    public func deleteCategory(id: UUID) {
        categories.removeAll { $0.id == id }
        // Batched into one write-back: see `normalizeSortOrders`.
        var updated = memes
        var changed = false
        for index in updated.indices where updated[index].categoryID == id {
            updated[index].categoryID = nil
            updated[index].updatedAt = .now
            changed = true
        }
        if changed { memes = updated }
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
            let compactContentHash = CompactContentHash(contentHash)
            guard !memes.contains(where: {
                $0.compactContentHash == compactContentHash
            }) else { return false }
            let stored = try repository.saveImageData(
                payload.data,
                fileExtension: payload.fileExtension,
                precomputedContentHash: contentHash
            )
            let targetCategory = categoryID ?? selectedCategoryID
            let nextOrder = (memes.filter { $0.categoryID == targetCategory }.map(\.sortOrder).max() ?? -1) + 1
            let meme = MemeItem(
                fileName: stored.fileName,
                contentHash: stored.contentHash,
                note: resolvedNote(note, ocrText: ocrText),
                ocrText: ocrText,
                categoryID: targetCategory,
                sortOrder: nextOrder
            )
            memes.append(meme)
            persistMemeDelta(meme, appending: true)
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
        persistMemeDelta(memes[index], appending: false)
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
        var updated = memes
        var changed = false
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].categoryID = categoryID
            updated[index].updatedAt = .now
            changed = true
        }
        if changed { memes = updated }
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
        persistCoalesced()
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
        persistCoalesced()
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
        filteredMemoPositionCount = 0
        repository.releaseTransientMemory()
    }

    var filteredMemoMetrics: (entryCount: Int, retainedPositionCount: Int) {
        (filteredMemo.count, filteredMemoPositionCount)
    }

    public func report(_ error: Error) { lastError = error.localizedDescription }

    public func snapshot() -> MemeSnapshot { MemeSnapshot(categories: categories, memes: memes) }

    public func importArchive(_ manifest: MemeArchiveManifest, imagesURL: URL) {
        guard let memeSnapshot = manifest.memeSnapshot else { return }
        do {
            try importArchive(
                categories: memeSnapshot.categories,
                imagesURL: imagesURL
            ) { consume in
                for meme in memeSnapshot.memes { try consume(meme) }
            }
        } catch {
            report(error)
        }
    }

    /// Imports a record source without requiring the whole archive item array
    /// to exist in memory. The caller may decode JSONL one record at a time;
    /// categories and the final published batch retain the existing behavior.
    public func importArchive(
        categories archiveCategories: [MemeCategory],
        imagesURL: URL,
        enumerateMemes: (
            _ consume: (MemeItem) throws -> Void
        ) throws -> Void
    ) throws {

        // Build the import in local values and publish once. The former loop
        // called addCategory/addImageData per item, re-encoding the complete
        // library JSON and invalidating the grid after every single image.
        var categoryMap = [UUID: UUID]()
        var categoryIDsByName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0.id) })
        var importedCategories: [MemeCategory] = []
        for category in archiveCategories {
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

        let knownHashes = try FileBackedHashIndex(
            existingHashes: memes.lazy.map(\.contentHash)
        )
        let seededHashCount = knownHashes.storedHashCount
        var candidateHashCount = 0
        var acceptedHashCount = 0
        defer {
            lastImportHashIndexMetrics = ImportHashIndexMetrics(
                seededHashCount: seededHashCount,
                candidateHashCount: candidateHashCount,
                acceptedHashCount: acceptedHashCount,
                peakResidentHashCount: knownHashes.peakResidentHashCount
            )
        }
        var nextOrderByCategory: [UUID?: Int] = [:]
        for meme in memes {
            nextOrderByCategory[meme.categoryID] = max(
                nextOrderByCategory[meme.categoryID] ?? 0,
                meme.sortOrder + 1
            )
        }
        var importedMemes: [MemeItem] = []
        do {
            try enumerateMemes { meme in
                guard let url = MemeArchiveService.safeContainedURL(base: imagesURL, fileName: meme.fileName),
                      let payload = ImageAssetData(fileURL: url) else { return }
                let contentHash = payload.data.clipboardContentHash
                candidateHashCount += 1
                guard try knownHashes.insertIfNew(contentHash) else { return }
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
                    acceptedHashCount += 1
                } catch let saveError {
                    // A failed write must not reserve the hash: another archive entry
                    // with the same bytes may still be importable.
                    try knownHashes.remove(contentHash)
                    lastError = saveError.localizedDescription
                }
            }
        } catch {
            for imported in importedMemes {
                try? repository.removeImage(named: imported.fileName)
            }
            throw error
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
    ///
    /// The whole pass writes back once. `memes` is `@Published`, so assigning
    /// through it element by element copied the entire library per element —
    /// quadratic work on a path that runs for every step of a drag.
    private func normalizeSortOrders() {
        var updated = memes
        var nextOrder = [UUID?: Int]()
        var changed = false
        for index in updated.indices {
            let category = updated[index].categoryID
            let order = nextOrder[category, default: 0]
            if updated[index].sortOrder != order {
                updated[index].sortOrder = order
                changed = true
            }
            nextOrder[category] = order + 1
        }
        guard changed else { return }
        memes = updated
    }

    private func persist() {
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        writeSnapshot()
    }

    private func persistCategoryDelta(_ category: MemeCategory, appending: Bool) {
        repository.saveDeltaAsync(
            categoryUpserts: [category],
            appendingCategoryIDs: appending ? [category.id] : []
        ) { [weak self] errorMessage in
            guard let errorMessage else { return }
            Task { @MainActor [weak self] in
                self?.lastError = errorMessage
            }
        }
    }

    private func persistMemeDelta(_ meme: MemeItem, appending: Bool) {
        repository.saveDeltaAsync(
            memeUpserts: [meme],
            appendingMemeIDs: appending ? [meme.id] : []
        ) { [weak self] errorMessage in
            Task { @MainActor [weak self] in
                if let errorMessage {
                    self?.lastError = errorMessage
                } else {
                    self?.deferPersistedBody(matching: meme)
                }
            }
        }
    }

    private func persistCoalesced() {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSaveWork = nil
            self?.writeSnapshot()
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func writeSnapshot() {
        let snapshot = snapshot()
        repository.saveAsync(snapshot) { [weak self] errorMessage, didWrite in
            Task { @MainActor [weak self] in
                if let errorMessage {
                    self?.lastError = errorMessage
                } else if didWrite {
                    self?.deferPersistedBodiesInOrder(matching: snapshot.memes)
                }
            }
        }
    }

    private func deferPersistedBody(matching persisted: MemeItem) {
        guard let index = memes.firstIndex(where: { $0.id == persisted.id }) else {
            return
        }
        let current = memes[index]
        guard current.decodedStoredTextByteCount > 0,
              current.compactContentHash == persisted.compactContentHash,
              current.updatedAt == persisted.updatedAt else { return }
        memes[index] = repository.deferredProjection(of: current)
        repository.releaseTransientTextCache()
    }

    private func deferPersistedBodiesInOrder(
        matching persistedMemes: [MemeItem]
    ) {
        var compacted: [MemeItem]?
        for index in 0..<min(memes.count, persistedMemes.count) {
            let current = memes[index]
            let persisted = persistedMemes[index]
            guard current.decodedStoredTextByteCount > 0,
                  current.id == persisted.id,
                  current.compactContentHash == persisted.compactContentHash,
                  current.updatedAt == persisted.updatedAt else {
                continue
            }
            if compacted == nil { compacted = memes }
            compacted?[index] = repository.deferredProjection(of: current)
        }
        if let compacted { memes = compacted }
        repository.releaseTransientTextCache()
    }

    /// Durability barrier for application termination and deterministic tests.
    public func flushPendingSave() {
        if pendingSaveWork != nil {
            pendingSaveWork?.cancel()
            pendingSaveWork = nil
            writeSnapshot()
        }
        repository.flushSnapshotWrites()
    }
}
