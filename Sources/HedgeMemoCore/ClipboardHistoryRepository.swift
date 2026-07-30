import AppKit
import CryptoKit
import Foundation

public final class ClipboardHistoryRepository: @unchecked Sendable {
    private struct PendingSnapshotWrite: @unchecked Sendable {
        let generation: Int
        let snapshot: ClipboardHistorySnapshot
        let completion: @Sendable (String?, Bool) -> Void
    }

    public let rootURL: URL
    public let imagesURL: URL
    public let originalFormatsURL: URL
    /// Kept as a read-only migration backup after SQLite becomes canonical.
    private let legacySnapshotURL: URL
    let databaseURL: URL
    private let database: ClipboardHistoryDatabase
    private lazy var textProvider = ClipboardEntryTextProvider { [database] id in
        database.loadText(id: id)
    }
    private let fileManager: FileManager
    private let snapshotIO: RepositoryIOCoordinator
    private let pendingGenerationLock = NSLock()
    private var latestQueuedGeneration = 0
    private var pendingSnapshotWrite: PendingSnapshotWrite?
    private var snapshotWriteInFlight = false
    private var peakRetainedSnapshotCount = 0
    private var completedWriteCount = 0
    private var latestMutationCounts = ClipboardHistoryDatabase.MutationCounts(
        changedEntries: 0,
        deletedEntries: 0
    )

    public static let `default` = ClipboardHistoryRepository()

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        let resolvedRoot = rootURL ?? AppSupportLocation.defaultRoot(fileManager: fileManager)
        self.fileManager = fileManager
        self.rootURL = resolvedRoot
        self.imagesURL = self.rootURL.appendingPathComponent("clipboard-images", isDirectory: true)
        self.originalFormatsURL = self.rootURL.appendingPathComponent("clipboard-formats", isDirectory: true)
        self.legacySnapshotURL = self.rootURL.appendingPathComponent("clipboard-history.json")
        let resolvedDatabaseURL = self.rootURL.appendingPathComponent("clipboard-history.sqlite3")
        self.databaseURL = resolvedDatabaseURL
        self.database = ClipboardHistoryDatabase(url: resolvedDatabaseURL)
        self.snapshotIO = .shared(scope: "clipboard", rootURL: resolvedRoot)
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: originalFormatsURL, withIntermediateDirectories: true)
    }

    /// True once history has ever been written. Used to tell a fresh install
    /// (no snapshot yet) from an update by a user who already has clipboard data.
    public var hasPersistedHistory: Bool {
        snapshotIO.sync {
            (try? database.isInitialized) == true
                || fileManager.fileExists(atPath: legacySnapshotURL.path)
        }
    }

    public func load() throws -> ClipboardHistorySnapshot {
        try snapshotIO.sync {
            try prepare()
            if database.exists, try database.isInitialized {
                return try database.load(textProvider: textProvider)
            }
            guard fileManager.fileExists(atPath: legacySnapshotURL.path) else {
                return ClipboardHistorySnapshot()
            }
            // One-time migration from the former monolithic JSON snapshot.
            // The source file remains untouched as a recovery backup until a
            // later maintenance policy explicitly retires it.
            let data = try Data(contentsOf: legacySnapshotURL, options: .mappedIfSafe)
            var snapshot = try JSONDecoder.clipboardDecoder.decode(
                ClipboardHistorySnapshot.self,
                from: data
            )
            snapshot.settings.normalize()
            latestMutationCounts = try database.save(snapshot)
            snapshot.entries = snapshot.entries.map { entry in
                var deferred = entry
                deferred.deferText(
                    to: textProvider,
                    automaticCategory: entry.contentCategory
                )
                return deferred
            }
            return snapshot
        }
    }

    public func releaseTransientTextCache() {
        textProvider.removeAll()
    }

    /// Releases both decoded bodies and SQLite's reusable reader page cache.
    /// Stored models keep their lazy provider, so this has no data or display
    /// effect; a later access simply opens a fresh bounded reader.
    public func releaseTransientMemory() {
        textProvider.removeAll()
        database.releaseTextReaderConnection()
    }

    func deferredProjection(of entry: ClipboardEntry) -> ClipboardEntry {
        var deferred = entry
        deferred.deferText(
            to: textProvider,
            automaticCategory: entry.automaticContentCategory
        )
        return deferred
    }

    /// Switches an already-deferred import entry from its disposable text
    /// source to the canonical database provider without rebuilding or
    /// publishing the entry array.
    func redirectDeferredTextToRepository(for entry: ClipboardEntry) {
        entry.redirectDeferredText(to: textProvider)
    }

    public func save(_ snapshot: ClipboardHistorySnapshot) throws {
        try snapshotIO.sync { try saveImmediately(snapshot) }
    }

    /// Enqueues a snapshot write with a single replaceable pending slot.
    ///
    /// Writes are serialized, so a burst of mutations — a paste queue being
    /// filled, an import, a run of quick copies — used to queue one complete
    /// re-encode of the entire history per mutation, each one obsolete by the
    /// time it ran. Each serial-queue marker retains only its generation;
    /// snapshot arrays and callbacks live in the single pending slot. Together
    /// with one already-writing generation this bounds retained full-library
    /// snapshots at two while preserving ordering relative to row deltas.
    public func saveAsync(
        _ snapshot: ClipboardHistorySnapshot,
        completion: @escaping @Sendable (_ errorMessage: String?, _ didWrite: Bool) -> Void
    ) {
        let (generation, supersededCompletion) = pendingGenerationLock.withLock {
            latestQueuedGeneration += 1
            let generation = latestQueuedGeneration
            let supersededCompletion = pendingSnapshotWrite?.completion
            pendingSnapshotWrite = PendingSnapshotWrite(
                generation: generation,
                snapshot: snapshot,
                completion: completion
            )
            updatePeakRetainedSnapshotCountLocked()
            return (generation, supersededCompletion)
        }
        supersededCompletion?(nil, false)
        snapshotIO.async { [self] in
            performPendingSnapshotWrite(generation: generation)
        }
    }

    private func performPendingSnapshotWrite(generation: Int) {
        let work: PendingSnapshotWrite? = pendingGenerationLock.withLock {
            guard pendingSnapshotWrite?.generation == generation else {
                return nil
            }
            let work = pendingSnapshotWrite
            pendingSnapshotWrite = nil
            snapshotWriteInFlight = true
            updatePeakRetainedSnapshotCountLocked()
            return work
        }
        guard let work else { return }

        do {
            try saveImmediately(work.snapshot)
            work.completion(nil, true)
        } catch {
            work.completion(error.localizedDescription, false)
        }
        pendingGenerationLock.withLock {
            snapshotWriteInFlight = false
        }
    }

    private func updatePeakRetainedSnapshotCountLocked() {
        let retained = (snapshotWriteInFlight ? 1 : 0)
            + (pendingSnapshotWrite == nil ? 0 : 1)
        peakRetainedSnapshotCount = max(peakRetainedSnapshotCount, retained)
    }

    /// Incremental hot-path persistence. Unlike a snapshot generation, a delta
    /// is never skipped: each one represents a distinct capture/delete event
    /// and the shared serial coordinator preserves their source order.
    public func saveDeltaAsync(
        upserts: [ClipboardEntry],
        deletedIDs: [UUID] = [],
        appendingIDs: Set<UUID> = [],
        settings: ClipboardHistorySettings,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        snapshotIO.async { [self] in
            do {
                try prepare()
                latestMutationCounts = try database.apply(
                    upserts: upserts,
                    deletedIDs: deletedIDs,
                    appendingIDs: appendingIDs,
                    settings: settings
                )
                pendingGenerationLock.withLock { completedWriteCount += 1 }
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    public func flushSnapshotWrites() {
        snapshotIO.flush()
    }

    /// Test/diagnostic counter for verifying that burst coalescing actually
    /// reduces physical snapshot replacements rather than merely reordering
    /// them. Protected by the same lock as the generation state.
    var completedSnapshotWriteCount: Int {
        pendingGenerationLock.withLock { completedWriteCount }
    }

    var peakRetainedFullSnapshotCount: Int {
        pendingGenerationLock.withLock { peakRetainedSnapshotCount }
    }

    var hasTransientTextReaderConnection: Bool {
        database.hasTextReaderConnection
    }

    var lastDatabaseMutationCounts: (changedEntries: Int, deletedEntries: Int) {
        snapshotIO.sync {
            (
                latestMutationCounts.changedEntries,
                latestMutationCounts.deletedEntries
            )
        }
    }

    var lastDatabaseBackfillMetrics: (
        rowCount: Int,
        peakResidentRowCount: Int
    ) {
        snapshotIO.sync {
            (
                database.lastBackfillRowCount,
                database.lastBackfillPeakResidentRowCount
            )
        }
    }

    private func saveImmediately(_ snapshot: ClipboardHistorySnapshot) throws {
        try HedgeMemoPerformance.measure("ClipboardSnapshotWrite") {
            try prepare()
            var normalized = snapshot
            normalized.settings.normalize()
            latestMutationCounts = try database.save(normalized)
            pendingGenerationLock.withLock { completedWriteCount += 1 }
        }
    }

    public func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let fileName = entry.imageFileName else { return nil }
        return imagesURL.appendingPathComponent(fileName)
    }

    @discardableResult
    public func saveImageData(
        _ data: Data,
        named id: UUID = UUID(),
        fileExtension: String = "png"
    ) throws -> StoredImage {
        try saveImageData(
            data,
            named: id,
            fileExtension: fileExtension,
            precomputedContentHash: data.clipboardContentHash
        )
    }

    func saveImageData(
        _ data: Data,
        named id: UUID = UUID(),
        fileExtension: String = "png",
        precomputedContentHash: String
    ) throws -> StoredImage {
        try prepare()
        let safeExtension = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fileName = "\(id.uuidString.lowercased()).\(safeExtension.isEmpty ? "png" : safeExtension)"
        try data.write(to: imagesURL.appendingPathComponent(fileName), options: .atomic)
        return StoredImage(
            fileName: fileName,
            contentHash: precomputedContentHash
        )
    }

    public func removeImage(named fileName: String) throws {
        let url = imagesURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func saveOriginalFormats(
        _ formats: [ClipboardFormatData],
        storageID: UUID = UUID()
    ) throws -> [ClipboardOriginalFormat] {
        guard !formats.isEmpty else { return [] }
        try prepare()
        var stored: [ClipboardOriginalFormat] = []
        do {
            for (index, format) in formats.enumerated() {
                let fileName = "\(storageID.uuidString.lowercased())-\(index).\(Self.fileExtension(for: format.typeIdentifier))"
                try format.data.write(
                    to: originalFormatsURL.appendingPathComponent(fileName),
                    options: .atomic
                )
                stored.append(
                    ClipboardOriginalFormat(
                        typeIdentifier: format.typeIdentifier,
                        fileName: fileName,
                        byteCount: format.data.count
                    )
                )
            }
            return stored
        } catch {
            for format in stored {
                try? fileManager.removeItem(at: originalFormatsURL.appendingPathComponent(format.fileName))
            }
            throw error
        }
    }

    public func originalFormatURL(for format: ClipboardOriginalFormat) throws -> URL {
        guard Self.isSafeSidecarFileName(format.fileName) else {
            throw ClipboardRichTextError.unsafeStoredFileName(format.fileName)
        }
        return originalFormatsURL.appendingPathComponent(format.fileName)
    }

    public func loadOriginalFormats(for entry: ClipboardEntry) throws -> [ClipboardFormatData] {
        var totalByteCount = 0
        return try (entry.originalFormats ?? []).map { format in
            let data = try Data(contentsOf: originalFormatURL(for: format))
            guard data.count == format.byteCount else {
                throw ClipboardRichTextError.missingRepresentation(format.typeIdentifier)
            }
            let (newTotal, overflow) = totalByteCount.addingReportingOverflow(data.count)
            guard !overflow, newTotal <= ClipboardRichTextPayload.maxOriginalFormatByteCount else {
                throw ClipboardRichTextError.originalFormatsTooLarge(newTotal)
            }
            totalByteCount = newTotal
            return ClipboardFormatData(typeIdentifier: format.typeIdentifier, data: data)
        }
    }

    public func removeOriginalFormats(_ formats: [ClipboardOriginalFormat]) throws {
        for format in formats {
            let url = try originalFormatURL(for: format)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func fileExtension(for typeIdentifier: String) -> String {
        switch NSPasteboard.PasteboardType(typeIdentifier) {
        case .rtfd: "rtfd"
        case .rtf: "rtf"
        case .html: "html"
        default: "data"
        }
    }

    private static func isSafeSidecarFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && !fileName.hasPrefix(".")
            && !fileName.contains("/")
            && !fileName.contains("\\")
    }
}

public extension Data {
    var clipboardContentHash: String {
        SHA256.hash(data: self).clipboardHexString
    }
}

private extension JSONDecoder {
    static let clipboardDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension SHA256Digest {
    var clipboardHexString: String { map { String(format: "%02x", $0) }.joined() }
}
