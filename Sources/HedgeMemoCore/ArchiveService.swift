import Foundation

/// A self-identifying ZIP payload. Version 2 stores independent optional
/// sections so a user can export just selected meme categories, clipboard
/// categories, or both without ever treating arbitrary ZIP files as imports.
public struct MemeArchiveManifest: Codable, Sendable {
    public static let formatVersion = 2

    public let formatVersion: Int
    public let exportedAt: Date
    public let memeSnapshot: MemeSnapshot?
    public let clipboardSnapshot: ClipboardHistorySnapshot?

    public init(memeSnapshot: MemeSnapshot?, clipboardSnapshot: ClipboardHistorySnapshot?) {
        self.formatVersion = Self.formatVersion
        self.exportedAt = .now
        self.memeSnapshot = memeSnapshot
        self.clipboardSnapshot = clipboardSnapshot
    }

    /// Version 1 archives contained only `snapshot`; preserve their contents
    /// while rejecting anything that is not a HedgeMemo manifest.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, snapshot, memeSnapshot, clipboardSnapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version == 1 || version == Self.formatVersion else { throw MemeRepositoryError.invalidArchive }
        formatVersion = version
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        if version == 1 {
            memeSnapshot = try container.decode(MemeSnapshot.self, forKey: .snapshot)
            clipboardSnapshot = nil
        } else {
            memeSnapshot = try container.decodeIfPresent(MemeSnapshot.self, forKey: .memeSnapshot)
            clipboardSnapshot = try container.decodeIfPresent(ClipboardHistorySnapshot.self, forKey: .clipboardSnapshot)
            guard memeSnapshot != nil || clipboardSnapshot != nil else { throw MemeRepositoryError.invalidArchive }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encodeIfPresent(memeSnapshot, forKey: .memeSnapshot)
        try container.encodeIfPresent(clipboardSnapshot, forKey: .clipboardSnapshot)
    }
}

public enum MemeArchiveService {
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
        try fm.createDirectory(at: memeDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: clipboardDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = MemeArchiveManifest(memeSnapshot: memeSnapshot, clipboardSnapshot: clipboardSnapshot)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        for meme in memeSnapshot?.memes ?? [] {
            let source = memeRepository.imageURL(for: meme)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: memeDirectory.appendingPathComponent(meme.fileName))
        }
        for entry in clipboardSnapshot?.entries ?? [] {
            guard let source = clipboardRepository.imageURL(for: entry), fm.fileExists(atPath: source.path),
                  let fileName = entry.imageFileName else { continue }
            try fm.copyItem(at: source, to: clipboardDirectory.appendingPathComponent(fileName))
        }
        try run("/usr/bin/zip", ["-rq", destination.path, "."], currentDirectory: staging)
    }

    public static func extract(from archiveURL: URL) throws -> (manifest: MemeArchiveManifest, directory: URL) {
        let fm = FileManager.default
        let extraction = fm.temporaryDirectory.appendingPathComponent("hedgememo-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/unzip", ["-qq", archiveURL.path, "-d", extraction.path])
            let manifestURL = extraction.appendingPathComponent("manifest.json")
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(MemeArchiveManifest.self, from: data)
            return (manifest, extraction)
        } catch {
            try? fm.removeItem(at: extraction)
            throw MemeRepositoryError.invalidArchive
        }
    }

    public static func removeExtraction(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }

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
