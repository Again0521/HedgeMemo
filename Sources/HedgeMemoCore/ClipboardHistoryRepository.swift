import AppKit
import CryptoKit
import Foundation

public final class ClipboardHistoryRepository: @unchecked Sendable {
    public let rootURL: URL
    public let imagesURL: URL
    private let snapshotURL: URL
    private let fileManager: FileManager

    public static let `default` = ClipboardHistoryRepository()

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? AppSupportLocation.defaultRoot(fileManager: fileManager)
        self.imagesURL = self.rootURL.appendingPathComponent("clipboard-images", isDirectory: true)
        self.snapshotURL = self.rootURL.appendingPathComponent("clipboard-history.json")
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    /// True once history has ever been written. Used to tell a fresh install
    /// (no snapshot yet) from an update by a user who already has clipboard data.
    public var hasPersistedHistory: Bool {
        fileManager.fileExists(atPath: snapshotURL.path)
    }

    public func load() throws -> ClipboardHistorySnapshot {
        try prepare()
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return ClipboardHistorySnapshot() }
        let data = try Data(contentsOf: snapshotURL)
        var snapshot = try JSONDecoder.clipboardDecoder.decode(ClipboardHistorySnapshot.self, from: data)
        snapshot.settings.normalize()
        return snapshot
    }

    public func save(_ snapshot: ClipboardHistorySnapshot) throws {
        try prepare()
        var normalized = snapshot
        normalized.settings.normalize()
        let data = try JSONEncoder.clipboardEncoder.encode(normalized)
        try data.write(to: snapshotURL, options: .atomic)
    }

    public func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let fileName = entry.imageFileName else { return nil }
        return imagesURL.appendingPathComponent(fileName)
    }

    @discardableResult
    public func saveImage(_ image: NSImage, named id: UUID = UUID()) throws -> StoredImage {
        guard let data = image.pngData else { throw MemeRepositoryError.cannotEncodeImage }
        return try saveImageData(data, named: id)
    }

    @discardableResult
    public func saveImageData(
        _ data: Data,
        named id: UUID = UUID(),
        fileExtension: String = "png"
    ) throws -> StoredImage {
        try prepare()
        let safeExtension = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fileName = "\(id.uuidString.lowercased()).\(safeExtension.isEmpty ? "png" : safeExtension)"
        try data.write(to: imagesURL.appendingPathComponent(fileName), options: .atomic)
        return StoredImage(fileName: fileName, contentHash: SHA256.hash(data: data).clipboardHexString)
    }

    public func removeImage(named fileName: String) throws {
        let url = imagesURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

public extension Data {
    var clipboardContentHash: String {
        SHA256.hash(data: self).clipboardHexString
    }
}

private extension JSONEncoder {
    static let clipboardEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
