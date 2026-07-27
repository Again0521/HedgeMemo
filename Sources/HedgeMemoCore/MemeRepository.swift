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
    public let rootURL: URL
    public let imagesURL: URL
    private let snapshotURL: URL
    private let fileManager: FileManager
    private let snapshotIO: RepositoryIOCoordinator

    public static let `default` = MemeRepository()

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        let resolvedRoot = rootURL ?? AppSupportLocation.defaultRoot(fileManager: fileManager)
        self.fileManager = fileManager
        self.rootURL = resolvedRoot
        self.imagesURL = self.rootURL.appendingPathComponent("images", isDirectory: true)
        self.snapshotURL = self.rootURL.appendingPathComponent("library.json")
        self.snapshotIO = .shared(scope: "memes", rootURL: resolvedRoot)
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    /// True once a library has ever been written. Used to tell a fresh install
    /// (no snapshot yet) from an update by a user who already has memes.
    public var hasPersistedLibrary: Bool {
        snapshotIO.sync {
            fileManager.fileExists(atPath: snapshotURL.path)
        }
    }

    public func load() throws -> MemeSnapshot {
        try snapshotIO.sync {
            try prepare()
            guard fileManager.fileExists(atPath: snapshotURL.path) else { return MemeSnapshot() }
            let data = try Data(contentsOf: snapshotURL)
            return try JSONDecoder.memeDecoder.decode(MemeSnapshot.self, from: data)
        }
    }

    public func save(_ snapshot: MemeSnapshot) throws {
        try snapshotIO.sync { try saveImmediately(snapshot) }
    }

    public func saveAsync(
        _ snapshot: MemeSnapshot,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        snapshotIO.async { [self] in
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

    private func saveImmediately(_ snapshot: MemeSnapshot) throws {
        try HedgeMemoPerformance.measure("MemeSnapshotWrite") {
            try prepare()
            let data = try JSONEncoder.memeEncoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
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

private extension JSONEncoder {
    static let memeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
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
