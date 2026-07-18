import AppKit
import CryptoKit
import Foundation

public enum MemeRepositoryError: LocalizedError {
    case cannotEncodeImage
    case invalidArchive

    public var errorDescription: String? {
        switch self {
        case .cannotEncodeImage: "无法将图片编码为 PNG。"
        case .invalidArchive: "压缩包内容不完整或格式不正确。"
        }
    }
}

public final class MemeRepository: @unchecked Sendable {
    public let rootURL: URL
    public let imagesURL: URL
    private let snapshotURL: URL
    private let fileManager: FileManager

    public static let `default` = MemeRepository()

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? AppSupportLocation.defaultRoot(fileManager: fileManager)
        self.imagesURL = self.rootURL.appendingPathComponent("images", isDirectory: true)
        self.snapshotURL = self.rootURL.appendingPathComponent("library.json")
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    public func load() throws -> MemeSnapshot {
        try prepare()
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return MemeSnapshot() }
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder.memeDecoder.decode(MemeSnapshot.self, from: data)
    }

    public func save(_ snapshot: MemeSnapshot) throws {
        try prepare()
        let data = try JSONEncoder.memeEncoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    public func imageURL(for meme: MemeItem) -> URL {
        imagesURL.appendingPathComponent(meme.fileName)
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
        return StoredImage(fileName: fileName, contentHash: SHA256.hash(data: data).hexString)
    }

    public func removeImage(named fileName: String) throws {
        let url = imagesURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func replaceImageData(_ data: Data, with fileName: String) throws {
        try prepare()
        try data.write(to: imagesURL.appendingPathComponent(fileName), options: .atomic)
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
