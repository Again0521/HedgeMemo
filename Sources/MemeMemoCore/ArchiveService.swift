import Foundation

public struct MemeArchiveManifest: Codable, Sendable {
    public static let formatVersion = 1
    public let formatVersion: Int
    public let exportedAt: Date
    public let snapshot: MemeSnapshot

    public init(snapshot: MemeSnapshot) {
        self.formatVersion = Self.formatVersion
        self.exportedAt = .now
        self.snapshot = snapshot
    }
}

public enum MemeArchiveService {
    public static func export(snapshot: MemeSnapshot, repository: MemeRepository, destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("memememo-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let imageDirectory = staging.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(MemeArchiveManifest(snapshot: snapshot)).write(to: staging.appendingPathComponent("manifest.json"))
        for meme in snapshot.memes {
            let source = repository.imageURL(for: meme)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: imageDirectory.appendingPathComponent(meme.fileName))
        }
        try run("/usr/bin/zip", ["-rq", destination.path, "."], currentDirectory: staging)
    }

    public static func extract(from archiveURL: URL) throws -> (manifest: MemeArchiveManifest, directory: URL) {
        let fm = FileManager.default
        let extraction = fm.temporaryDirectory.appendingPathComponent("memememo-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/unzip", ["-qq", archiveURL.path, "-d", extraction.path])
            let manifestURL = extraction.appendingPathComponent("manifest.json")
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(MemeArchiveManifest.self, from: data)
            guard manifest.formatVersion == MemeArchiveManifest.formatVersion else { throw MemeRepositoryError.invalidArchive }
            return (manifest, extraction)
        } catch {
            try? fm.removeItem(at: extraction)
            throw error
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
