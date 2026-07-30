import Foundation

/// A self-identifying ZIP payload. Version 3 keeps only the small catalog in
/// this manifest and stores large item bodies as newline-delimited records.
/// Versions 1 and 2 remain decodable for imports made by earlier releases.
public struct MemeArchiveManifest: Codable, Sendable {
    public static let formatVersion = 3

    public let formatVersion: Int
    public let exportedAt: Date
    public let memeSnapshot: MemeSnapshot?
    public let clipboardSnapshot: ClipboardHistorySnapshot?
    public let memeCategories: [MemeCategory]?
    public let containsUncategorizedMemes: Bool
    public let clipboardSettings: ClipboardHistorySettings?
    public let clipboardCategoryStorageValues: [String]
    public let memeRecordCount: Int
    public let clipboardRecordCount: Int

    /// In-memory/legacy convenience used by existing callers and tests. New ZIP
    /// exports use the catalog initializer below and write version 3 records.
    public init(memeSnapshot: MemeSnapshot?, clipboardSnapshot: ClipboardHistorySnapshot?) {
        self.formatVersion = 2
        self.exportedAt = .now
        self.memeSnapshot = memeSnapshot
        self.clipboardSnapshot = clipboardSnapshot
        self.memeCategories = nil
        self.containsUncategorizedMemes = false
        self.clipboardSettings = nil
        self.clipboardCategoryStorageValues = []
        self.memeRecordCount = 0
        self.clipboardRecordCount = 0
    }

    init(streamingMemeSnapshot: MemeSnapshot?, clipboardSnapshot: ClipboardHistorySnapshot?) {
        self.formatVersion = Self.formatVersion
        self.exportedAt = .now
        self.memeSnapshot = nil
        self.clipboardSnapshot = nil
        self.memeCategories = streamingMemeSnapshot?.categories
        self.containsUncategorizedMemes =
            streamingMemeSnapshot?.memes.contains(where: { $0.categoryID == nil }) == true
        self.clipboardSettings = clipboardSnapshot?.settings
        self.clipboardCategoryStorageValues = Self.clipboardCategoryKeys(
            in: clipboardSnapshot
        )
        self.memeRecordCount = streamingMemeSnapshot?.memes.count ?? 0
        self.clipboardRecordCount = clipboardSnapshot?.entries.count ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, snapshot, memeSnapshot, clipboardSnapshot
        case memeCategories, containsUncategorizedMemes, clipboardSettings
        case clipboardCategoryStorageValues, memeRecordCount, clipboardRecordCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.formatVersion).contains(version) else {
            throw MemeRepositoryError.invalidArchive
        }
        formatVersion = version
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        if version == 1 {
            memeSnapshot = try container.decode(MemeSnapshot.self, forKey: .snapshot)
            clipboardSnapshot = nil
            memeCategories = nil
            containsUncategorizedMemes = false
            clipboardSettings = nil
            clipboardCategoryStorageValues = []
            memeRecordCount = 0
            clipboardRecordCount = 0
        } else if version == 2 {
            memeSnapshot = try container.decodeIfPresent(MemeSnapshot.self, forKey: .memeSnapshot)
            clipboardSnapshot = try container.decodeIfPresent(ClipboardHistorySnapshot.self, forKey: .clipboardSnapshot)
            guard memeSnapshot != nil || clipboardSnapshot != nil else { throw MemeRepositoryError.invalidArchive }
            memeCategories = nil
            containsUncategorizedMemes = false
            clipboardSettings = nil
            clipboardCategoryStorageValues = []
            memeRecordCount = 0
            clipboardRecordCount = 0
        } else {
            memeSnapshot = nil
            clipboardSnapshot = nil
            memeCategories = try container.decodeIfPresent(
                [MemeCategory].self,
                forKey: .memeCategories
            )
            containsUncategorizedMemes = try container.decodeIfPresent(
                Bool.self,
                forKey: .containsUncategorizedMemes
            ) ?? false
            clipboardSettings = try container.decodeIfPresent(
                ClipboardHistorySettings.self,
                forKey: .clipboardSettings
            )
            clipboardCategoryStorageValues = try container.decodeIfPresent(
                [String].self,
                forKey: .clipboardCategoryStorageValues
            ) ?? []
            memeRecordCount = try container.decodeIfPresent(
                Int.self,
                forKey: .memeRecordCount
            ) ?? 0
            clipboardRecordCount = try container.decodeIfPresent(
                Int.self,
                forKey: .clipboardRecordCount
            ) ?? 0
            guard memeRecordCount >= 0,
                  clipboardRecordCount >= 0,
                  memeRecordCount > 0
                    || clipboardRecordCount > 0
                    || memeCategories != nil
                    || clipboardSettings != nil else {
                throw MemeRepositoryError.invalidArchive
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        if formatVersion == 1 {
            try container.encodeIfPresent(memeSnapshot, forKey: .snapshot)
        } else if formatVersion == 2 {
            try container.encodeIfPresent(memeSnapshot, forKey: .memeSnapshot)
            try container.encodeIfPresent(clipboardSnapshot, forKey: .clipboardSnapshot)
        } else {
            try container.encodeIfPresent(memeCategories, forKey: .memeCategories)
            try container.encode(
                containsUncategorizedMemes,
                forKey: .containsUncategorizedMemes
            )
            try container.encodeIfPresent(clipboardSettings, forKey: .clipboardSettings)
            try container.encode(
                clipboardCategoryStorageValues,
                forKey: .clipboardCategoryStorageValues
            )
            try container.encode(memeRecordCount, forKey: .memeRecordCount)
            try container.encode(clipboardRecordCount, forKey: .clipboardRecordCount)
        }
    }

    public var availableMemeCategories: [MemeCategory] {
        memeSnapshot?.categories ?? memeCategories ?? []
    }

    public var hasUncategorizedMemes: Bool {
        memeSnapshot?.memes.contains(where: { $0.categoryID == nil })
            ?? containsUncategorizedMemes
    }

    public var availableClipboardSettings: ClipboardHistorySettings? {
        clipboardSnapshot?.settings ?? clipboardSettings
    }

    public var availableClipboardCategoryKeys: [ClipboardCategoryKey] {
        if let snapshot = clipboardSnapshot {
            return Self.clipboardCategoryKeys(in: snapshot).compactMap(
                ClipboardCategoryKey.init(storageValue:)
            )
        }
        return clipboardCategoryStorageValues.compactMap(
            ClipboardCategoryKey.init(storageValue:)
        )
    }

    public var containsMemeRecords: Bool {
        !(memeSnapshot?.memes.isEmpty ?? true) || memeRecordCount > 0
    }

    public var containsClipboardRecords: Bool {
        !(clipboardSnapshot?.entries.isEmpty ?? true) || clipboardRecordCount > 0
    }

    private static func clipboardCategoryKeys(
        in snapshot: ClipboardHistorySnapshot?
    ) -> [String] {
        guard let snapshot else { return [] }
        var keys = ClipboardContentCategory.allCases
            .filter { category in
                snapshot.entries.contains { $0.contentCategory == category }
            }
            .map { ClipboardCategoryKey.builtin($0).storageValue }
        let customs = snapshot.settings.customCategories ?? []
        keys += customs.compactMap { custom in
            let key = ClipboardCategoryKey.custom(custom.id)
            return snapshot.entries.contains {
                $0.matches(key: key, customCategories: customs)
            } ? key.storageValue : nil
        }
        return keys
    }
}

public struct ExtractedMemeArchive: Sendable {
    public let manifest: MemeArchiveManifest
    public let directory: URL
}

public enum MemeArchiveService {
    private static let memeRecordsFileName = "meme-items.jsonl"
    private static let clipboardRecordsFileName = "clipboard-entries.jsonl"

    struct EncodingMetrics: Equatable {
        let encodedRecordCount: Int
        let largestEncodedRecordByteCount: Int
    }

    public static func export(
        memeSnapshot: MemeSnapshot?,
        memeRepository: MemeRepository,
        clipboardSnapshot: ClipboardHistorySnapshot?,
        clipboardRepository: ClipboardHistoryRepository,
        destination: URL
    ) throws {
        guard memeSnapshot != nil || clipboardSnapshot != nil else { throw MemeRepositoryError.invalidArchive }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("hedgememo-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let memeDirectory = staging.appendingPathComponent("meme-images", isDirectory: true)
        let clipboardDirectory = staging.appendingPathComponent("clipboard-images", isDirectory: true)
        let clipboardFormatsDirectory = staging.appendingPathComponent("clipboard-formats", isDirectory: true)
        try fm.createDirectory(at: memeDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: clipboardDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: clipboardFormatsDirectory, withIntermediateDirectories: true)

        let manifest = MemeArchiveManifest(
            streamingMemeSnapshot: memeSnapshot,
            clipboardSnapshot: clipboardSnapshot
        )
        _ = try writeManifest(
            manifest,
            to: staging.appendingPathComponent("manifest.json")
        )
        if let memes = memeSnapshot?.memes {
            _ = try writeRecords(
                memes,
                to: staging.appendingPathComponent(memeRecordsFileName)
            )
        }
        if let entries = clipboardSnapshot?.entries {
            _ = try writeRecords(
                entries,
                to: staging.appendingPathComponent(clipboardRecordsFileName)
            )
        }

        for meme in memeSnapshot?.memes ?? [] {
            let source = memeRepository.imageURL(for: meme)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: memeDirectory.appendingPathComponent(meme.fileName))
        }
        for entry in clipboardSnapshot?.entries ?? [] {
            if let source = clipboardRepository.imageURL(for: entry),
               fm.fileExists(atPath: source.path),
               let fileName = entry.imageFileName {
                try fm.copyItem(at: source, to: clipboardDirectory.appendingPathComponent(fileName))
            }
            for format in entry.originalFormats ?? [] {
                let source = try clipboardRepository.originalFormatURL(for: format)
                try fm.copyItem(
                    at: source,
                    to: clipboardFormatsDirectory.appendingPathComponent(format.fileName)
                )
            }
        }
        try run("/usr/bin/zip", ["-rq", destination.path, "."], currentDirectory: staging)
    }

    public static func extract(from archiveURL: URL) throws -> ExtractedMemeArchive {
        let fm = FileManager.default
        let extraction = fm.temporaryDirectory.appendingPathComponent("hedgememo-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/unzip", ["-qq", archiveURL.path, "-d", extraction.path])
            try enforceExtractedSizeLimit(at: extraction)
            let manifestURL = extraction.appendingPathComponent("manifest.json")
            let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(MemeArchiveManifest.self, from: data)
            try validateRecordFiles(manifest: manifest, in: extraction)
            return ExtractedMemeArchive(manifest: manifest, directory: extraction)
        } catch {
            try? fm.removeItem(at: extraction)
            throw MemeRepositoryError.invalidArchive
        }
    }

    public static func removeExtraction(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }

    /// A malformed record must be rejected before any Store starts importing.
    /// This performs a bounded validation pass during extraction; the selected
    /// records are decoded again only after the user confirms the import.
    static func validateRecordFiles(
        manifest: MemeArchiveManifest,
        in directory: URL
    ) throws {
        guard manifest.formatVersion >= 3 else { return }
        if manifest.memeRecordCount > 0 {
            let url = try regularRecordURL(
                in: directory,
                fileName: memeRecordsFileName
            )
            let count: Int = try forEachJSONRecord(at: url) { (_: MemeItem) in }
            guard count == manifest.memeRecordCount else {
                throw MemeRepositoryError.invalidArchive
            }
        }
        if manifest.clipboardRecordCount > 0 {
            let url = try regularRecordURL(
                in: directory,
                fileName: clipboardRecordsFileName
            )
            let count: Int = try forEachJSONRecord(at: url) {
                (entry: ClipboardEntry) in
                let formatsDirectory = directory.appendingPathComponent(
                    "clipboard-formats",
                    isDirectory: true
                )
                for format in entry.originalFormats ?? [] {
                    _ = try regularContainedFileURL(
                        in: formatsDirectory,
                        fileName: format.fileName
                    )
                }
            }
            guard count == manifest.clipboardRecordCount else {
                throw MemeRepositoryError.invalidArchive
            }
        }
    }

    /// Decodes only one archive record at a time. Version 1/2 archives already
    /// carry decoded arrays in their manifest, so they use the compatibility
    /// path while every new version-3 archive stays streaming.
    @discardableResult
    public static func forEachMeme(
        in archive: ExtractedMemeArchive,
        _ consume: (MemeItem) throws -> Void
    ) throws -> Int {
        if archive.manifest.formatVersion < 3 {
            let memes = archive.manifest.memeSnapshot?.memes ?? []
            for meme in memes { try consume(meme) }
            return memes.count
        }
        guard archive.manifest.memeRecordCount > 0 else { return 0 }
        let url = try regularRecordURL(
            in: archive.directory,
            fileName: memeRecordsFileName
        )
        let count = try forEachJSONRecord(at: url, consume)
        guard count == archive.manifest.memeRecordCount else {
            throw MemeRepositoryError.invalidArchive
        }
        return count
    }

    @discardableResult
    public static func forEachClipboardEntry(
        in archive: ExtractedMemeArchive,
        _ consume: (ClipboardEntry) throws -> Void
    ) throws -> Int {
        if archive.manifest.formatVersion < 3 {
            let entries = archive.manifest.clipboardSnapshot?.entries ?? []
            for entry in entries { try consume(entry) }
            return entries.count
        }
        guard archive.manifest.clipboardRecordCount > 0 else { return 0 }
        let url = try regularRecordURL(
            in: archive.directory,
            fileName: clipboardRecordsFileName
        )
        let count = try forEachJSONRecord(at: url, consume)
        guard count == archive.manifest.clipboardRecordCount else {
            throw MemeRepositoryError.invalidArchive
        }
        return count
    }

    /// Writes either a legacy version-2 manifest or the compact version-3
    /// catalog one value at a time.
    @discardableResult
    static func writeManifest(
        _ manifest: MemeArchiveManifest,
        to destination: URL
    ) throws -> EncodingMetrics {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw MemeRepositoryError.invalidArchive
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let writer = ArchiveJSONStreamWriter(handle: handle)

        try writer.writeLiteral("{\"formatVersion\":")
        try writer.writeEncoded(manifest.formatVersion)
        try writer.writeLiteral(",\"exportedAt\":")
        try writer.writeEncoded(manifest.exportedAt)

        if manifest.formatVersion >= 3 {
            if let categories = manifest.memeCategories {
                try writer.writeLiteral(",\"memeCategories\":")
                try writer.writeArray(categories)
            }
            try writer.writeLiteral(",\"containsUncategorizedMemes\":")
            try writer.writeEncoded(manifest.containsUncategorizedMemes)
            if let settings = manifest.clipboardSettings {
                try writer.writeLiteral(",\"clipboardSettings\":")
                try writer.writeEncoded(settings)
            }
            try writer.writeLiteral(",\"clipboardCategoryStorageValues\":")
            try writer.writeArray(manifest.clipboardCategoryStorageValues)
            try writer.writeLiteral(",\"memeRecordCount\":")
            try writer.writeEncoded(manifest.memeRecordCount)
            try writer.writeLiteral(",\"clipboardRecordCount\":")
            try writer.writeEncoded(manifest.clipboardRecordCount)
        } else if let snapshot = manifest.memeSnapshot {
            try writer.writeLiteral(",\"memeSnapshot\":{\"categories\":")
            try writer.writeArray(snapshot.categories)
            try writer.writeLiteral(",\"memes\":")
            try writer.writeArray(snapshot.memes)
            try writer.writeLiteral("}")
        }
        if let snapshot = manifest.clipboardSnapshot {
            try writer.writeLiteral(",\"clipboardSnapshot\":{\"entries\":")
            try writer.writeArray(snapshot.entries)
            try writer.writeLiteral(",\"settings\":")
            try writer.writeEncoded(snapshot.settings)
            try writer.writeLiteral("}")
        }
        try writer.writeLiteral("}")
        try handle.synchronize()
        return EncodingMetrics(
            encodedRecordCount: writer.encodedRecordCount,
            largestEncodedRecordByteCount: writer.largestEncodedRecordByteCount
        )
    }

    @discardableResult
    private static func writeRecords<Value: Encodable>(
        _ records: [Value],
        to destination: URL
    ) throws -> EncodingMetrics {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw MemeRepositoryError.invalidArchive
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let writer = ArchiveJSONStreamWriter(handle: handle)
        for record in records {
            try writer.writeEncoded(record)
            try writer.writeLiteral("\n")
        }
        try handle.synchronize()
        return EncodingMetrics(
            encodedRecordCount: writer.encodedRecordCount,
            largestEncodedRecordByteCount: writer.largestEncodedRecordByteCount
        )
    }

    /// Total bytes an imported archive may expand to. Meme/clipboard archives
    /// are images and a manifest — comfortably under this — so a payload past it
    /// is treated as a decompression bomb rather than extracted into temp space.
    private static let maxExtractedByteCount: Int64 = 2_000_000_000  // 2 GB

    private static func enforceExtractedSizeLimit(at directory: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
            ]
        ) else { return }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                throw MemeRepositoryError.invalidArchive
            }
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
            if total > maxExtractedByteCount { throw MemeRepositoryError.invalidArchive }
        }
    }

    /// Resolves a file named in a manifest against the extracted images
    /// directory, rejecting anything that could escape it. A crafted archive
    /// otherwise names `../../…` in its manifest to read files outside the
    /// sandboxed extraction directory during import.
    public static func safeContainedURL(base: URL, fileName: String) -> URL? {
        guard !fileName.isEmpty,
              !fileName.hasPrefix("."),
              !fileName.contains("/"),
              !fileName.contains("\\") else { return nil }
        let url = base.appendingPathComponent(fileName).standardizedFileURL
        let root = base.standardizedFileURL.path
        guard url.path == root + "/" + fileName || url.path.hasPrefix(root + "/") else { return nil }
        return url
    }

    private static func regularRecordURL(
        in directory: URL,
        fileName: String
    ) throws -> URL {
        try regularContainedFileURL(in: directory, fileName: fileName)
    }

    private static func regularContainedFileURL(
        in directory: URL,
        fileName: String
    ) throws -> URL {
        guard let url = safeContainedURL(base: directory, fileName: fileName)
        else {
            throw MemeRepositoryError.invalidArchive
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MemeRepositoryError.invalidArchive
        }
        return url
    }

    private static func forEachJSONRecord<Value: Decodable>(
        at url: URL,
        _ consume: (Value) throws -> Void
    ) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var buffer = Data()
        var count = 0

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let record = buffer.prefix(upTo: newline)
                guard !record.isEmpty else { throw MemeRepositoryError.invalidArchive }
                try consume(try decoder.decode(Value.self, from: Data(record)))
                count += 1
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty {
            try consume(try decoder.decode(Value.self, from: buffer))
            count += 1
        }
        return count
    }

    private static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MemeRepositoryError.invalidArchive }
    }
}

private final class ArchiveJSONStreamWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private(set) var encodedRecordCount = 0
    private(set) var largestEncodedRecordByteCount = 0

    init(handle: FileHandle) {
        self.handle = handle
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func writeLiteral(_ value: String) throws {
        try handle.write(contentsOf: Data(value.utf8))
    }

    func writeEncoded<Value: Encodable>(_ value: Value) throws {
        let data = try encoder.encode(value)
        encodedRecordCount += 1
        largestEncodedRecordByteCount = max(largestEncodedRecordByteCount, data.count)
        try handle.write(contentsOf: data)
    }

    func writeArray<Value: Encodable>(_ values: [Value]) throws {
        try writeLiteral("[")
        for (index, value) in values.enumerated() {
            if index > 0 { try writeLiteral(",") }
            try writeEncoded(value)
        }
        try writeLiteral("]")
    }
}
