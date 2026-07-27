import AppKit
import CryptoKit
import Foundation

public final class ClipboardHistoryRepository: @unchecked Sendable {
    public let rootURL: URL
    public let imagesURL: URL
    public let originalFormatsURL: URL
    private let snapshotURL: URL
    private let fileManager: FileManager
    private let snapshotIO: RepositoryIOCoordinator
    private let pendingGenerationLock = NSLock()
    private var latestQueuedGeneration = 0

    public static let `default` = ClipboardHistoryRepository()

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        let resolvedRoot = rootURL ?? AppSupportLocation.defaultRoot(fileManager: fileManager)
        self.fileManager = fileManager
        self.rootURL = resolvedRoot
        self.imagesURL = self.rootURL.appendingPathComponent("clipboard-images", isDirectory: true)
        self.originalFormatsURL = self.rootURL.appendingPathComponent("clipboard-formats", isDirectory: true)
        self.snapshotURL = self.rootURL.appendingPathComponent("clipboard-history.json")
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
            fileManager.fileExists(atPath: snapshotURL.path)
        }
    }

    public func load() throws -> ClipboardHistorySnapshot {
        try snapshotIO.sync {
            try prepare()
            guard fileManager.fileExists(atPath: snapshotURL.path) else { return ClipboardHistorySnapshot() }
            // A long history is a large file, and this read happens during
            // launch. Mapping it hands the pages to the decoder without first
            // copying the whole document into the heap.
            let data = try Data(contentsOf: snapshotURL, options: .mappedIfSafe)
            var snapshot = try JSONDecoder.clipboardDecoder.decode(ClipboardHistorySnapshot.self, from: data)
            snapshot.settings.normalize()
            return snapshot
        }
    }

    public func save(_ snapshot: ClipboardHistorySnapshot) throws {
        try snapshotIO.sync { try saveImmediately(snapshot) }
    }

    /// Enqueues a snapshot write, skipping generations that a newer enqueued
    /// snapshot has already superseded.
    ///
    /// Writes are serialized, so a burst of mutations — a paste queue being
    /// filled, an import, a run of quick copies — used to queue one complete
    /// re-encode of the entire history per mutation, each one obsolete by the
    /// time it ran. Only the newest pending snapshot is actually encoded; the
    /// superseded ones report success without doing the work, so callers (and
    /// the reload-as-barrier contract) still see the latest state on disk.
    public func saveAsync(
        _ snapshot: ClipboardHistorySnapshot,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        let generation = pendingGenerationLock.withLock { () -> Int in
            latestQueuedGeneration += 1
            return latestQueuedGeneration
        }
        snapshotIO.async { [self] in
            let isSuperseded = pendingGenerationLock.withLock {
                generation < latestQueuedGeneration
            }
            guard !isSuperseded else {
                completion(nil)
                return
            }
            do {
                try saveImmediately(snapshot)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    public func flushSnapshotWrites() {
        snapshotIO.flush()
    }

    private func saveImmediately(_ snapshot: ClipboardHistorySnapshot) throws {
        try HedgeMemoPerformance.measure("ClipboardSnapshotWrite") {
            try prepare()
            var normalized = snapshot
            normalized.settings.normalize()
            let data = try JSONEncoder.clipboardEncoder.encode(normalized)
            try data.write(to: snapshotURL, options: .atomic)
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

private extension JSONEncoder {
    /// Compact output on purpose. This document is rewritten whenever the
    /// history changes and can hold thousands of entries; pretty-printing and
    /// key sorting inflated it by roughly a third and added a per-object sort,
    /// for indentation nothing reads. The format is otherwise unchanged, so
    /// existing snapshots keep decoding.
    static let clipboardEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
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
