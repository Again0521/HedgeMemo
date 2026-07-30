import AppKit
import CryptoKit
import Foundation

public enum MemeRepositoryError: LocalizedError {
    case cannotEncodeImage
    case invalidArchive

    public var errorDescription: String? {
        switch self {
        case .cannotEncodeImage: L10n.text("无法将图片编码为 PNG。")
        case .invalidArchive: L10n.text("压缩包内容不完整或格式不正确。")
        }
    }
}

public final class MemeRepository: @unchecked Sendable {
    private struct PendingSnapshotWrite: @unchecked Sendable {
        let generation: Int
        let snapshot: MemeSnapshot
        let completion: @Sendable (String?, Bool) -> Void
    }

    public let rootURL: URL
    public let imagesURL: URL
    private let legacySnapshotURL: URL
    let databaseURL: URL
    private let database: MemeDatabase
    private lazy var textProvider = MemeTextProvider { [database] id in
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
    private var latestMutationCounts = MemeDatabase.MutationCounts(
        changedCategories: 0,
        deletedCategories: 0,
        changedMemes: 0,
        deletedMemes: 0
    )

    public static let `default` = MemeRepository()

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        let resolvedRoot = rootURL ?? AppSupportLocation.defaultRoot(fileManager: fileManager)
        self.fileManager = fileManager
        self.rootURL = resolvedRoot
        self.imagesURL = self.rootURL.appendingPathComponent("images", isDirectory: true)
        self.legacySnapshotURL = self.rootURL.appendingPathComponent("library.json")
        let resolvedDatabaseURL = self.rootURL.appendingPathComponent("meme-library.sqlite3")
        self.databaseURL = resolvedDatabaseURL
        self.database = MemeDatabase(url: resolvedDatabaseURL)
        self.snapshotIO = .shared(scope: "memes", rootURL: resolvedRoot)
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    /// True once a library has ever been written. Used to tell a fresh install
    /// (no snapshot yet) from an update by a user who already has memes.
    public var hasPersistedLibrary: Bool {
        snapshotIO.sync {
            (try? database.isInitialized) == true
                || fileManager.fileExists(atPath: legacySnapshotURL.path)
        }
    }

    public func load() throws -> MemeSnapshot {
        try snapshotIO.sync {
            try prepare()
            if database.exists, try database.isInitialized {
                return try database.load(textProvider: textProvider)
            }
            guard fileManager.fileExists(atPath: legacySnapshotURL.path) else {
                return MemeSnapshot()
            }
            let data = try Data(contentsOf: legacySnapshotURL, options: .mappedIfSafe)
            var snapshot = try JSONDecoder.memeDecoder.decode(MemeSnapshot.self, from: data)
            latestMutationCounts = try database.save(snapshot)
            snapshot.memes = snapshot.memes.map { meme in
                var deferred = meme
                deferred.deferText(to: textProvider)
                return deferred
            }
            return snapshot
        }
    }

    public func releaseTransientTextCache() {
        textProvider.removeAll()
    }

    public func releaseTransientMemory() {
        textProvider.removeAll()
        database.releaseTextReaderConnection()
    }

    func deferredProjection(of meme: MemeItem) -> MemeItem {
        var deferred = meme
        deferred.deferText(to: textProvider)
        return deferred
    }

    public func loadPage(
        categoryID: UUID? = nil,
        query: String = "",
        after cursor: MemePageCursor? = nil,
        limit: Int
    ) throws -> MemePage {
        try migrateLegacySnapshotIfNeeded()
        return try snapshotIO.sync {
            try prepare()
            return try database.loadPage(
                categoryID: categoryID,
                query: query,
                after: cursor,
                limit: limit
            )
        }
    }

    public func memeCount(categoryID: UUID? = nil, query: String = "") throws -> Int {
        try migrateLegacySnapshotIfNeeded()
        return try snapshotIO.sync {
            try prepare()
            return try database.count(categoryID: categoryID, query: query)
        }
    }

    private func migrateLegacySnapshotIfNeeded() throws {
        let needsMigration = try snapshotIO.sync {
            guard fileManager.fileExists(atPath: legacySnapshotURL.path) else { return false }
            guard database.exists else { return true }
            return try !database.isInitialized
        }
        if needsMigration { _ = try load() }
    }

    public func save(_ snapshot: MemeSnapshot) throws {
        try snapshotIO.sync { try saveImmediately(snapshot) }
    }

    /// Keeps only the newest not-yet-started full snapshot. Queue markers hold
    /// generation numbers rather than the replaced arrays, so a burst retains
    /// at most one in-flight and one pending library while row-delta ordering
    /// remains unchanged.
    public func saveAsync(
        _ snapshot: MemeSnapshot,
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

    public func saveDeltaAsync(
        categoryUpserts: [MemeCategory] = [],
        deletedCategoryIDs: [UUID] = [],
        memeUpserts: [MemeItem] = [],
        deletedMemeIDs: [UUID] = [],
        appendingCategoryIDs: Set<UUID> = [],
        appendingMemeIDs: Set<UUID> = [],
        completion: @escaping @Sendable (String?) -> Void
    ) {
        snapshotIO.async { [self] in
            do {
                try prepare()
                latestMutationCounts = try database.apply(
                    categoryUpserts: categoryUpserts,
                    deletedCategoryIDs: deletedCategoryIDs,
                    memeUpserts: memeUpserts,
                    deletedMemeIDs: deletedMemeIDs,
                    appendingCategoryIDs: appendingCategoryIDs,
                    appendingMemeIDs: appendingMemeIDs
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

    var completedSnapshotWriteCount: Int {
        pendingGenerationLock.withLock { completedWriteCount }
    }

    var peakRetainedFullSnapshotCount: Int {
        pendingGenerationLock.withLock { peakRetainedSnapshotCount }
    }

    var hasTransientTextReaderConnection: Bool {
        database.hasTextReaderConnection
    }

    var lastDatabaseMutationCounts: (
        changedCategories: Int,
        deletedCategories: Int,
        changedMemes: Int,
        deletedMemes: Int
    ) {
        snapshotIO.sync {
            (
                latestMutationCounts.changedCategories,
                latestMutationCounts.deletedCategories,
                latestMutationCounts.changedMemes,
                latestMutationCounts.deletedMemes
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

    private func saveImmediately(_ snapshot: MemeSnapshot) throws {
        try HedgeMemoPerformance.measure("MemeSnapshotWrite") {
            try prepare()
            latestMutationCounts = try database.save(snapshot)
            pendingGenerationLock.withLock { completedWriteCount += 1 }
        }
    }

    public func imageURL(for meme: MemeItem) -> URL {
        imagesURL.appendingPathComponent(meme.fileName)
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
            precomputedContentHash: SHA256.hash(data: data).hexString
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
}

public struct StoredImage: Sendable {
    public let fileName: String
    public let contentHash: String
}

public extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension JSONDecoder {
    static let memeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension SHA256Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
