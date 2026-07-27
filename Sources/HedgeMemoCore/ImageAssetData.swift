import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Original encoded image bytes plus their file format. Keeping the encoded
/// payload (instead of round-tripping every image through NSImage/PNG) preserves
/// GIF animation and lets pasteboard/file imports remain lossless.
public struct ImageAssetData: Sendable {
    public let data: Data
    public let fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = Self.normalizedExtension(fileExtension, data: data)
    }

    public init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL), Self.isValidImageData(data) else { return nil }
        self.init(data: data, fileExtension: fileURL.pathExtension)
    }

    @MainActor
    public static func read(from pasteboard: NSPasteboard, allowFileURLs: Bool = true) -> ImageAssetData? {
        let declaredTypes = Set(pasteboard.types ?? [])
        for candidate in pasteboardCandidates where declaredTypes.contains(candidate.type) {
            if let data = pasteboard.data(forType: candidate.type), Self.isValidImageData(data) {
                return ImageAssetData(data: data, fileExtension: candidate.extension)
            }
        }

        // `NSImage(pasteboard:)` may ask AppKit to synthesize an image from a
        // Finder file URL. Never invoke that conversion for background capture,
        // because it silently crosses into Documents/Desktop and triggers TCC.
        if allowFileURLs, let image = NSImage(pasteboard: pasteboard), let data = image.pngData {
            return ImageAssetData(data: data, fileExtension: "png")
        }

        if allowFileURLs {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first {
                return ImageAssetData(fileURL: url)
            }
        }
        return nil
    }

    /// Reads only the encoded image container instead of instantiating an
    /// `NSImage`. Capture paths need validation, not a full-size representation;
    /// display-size decoding remains the thumbnail pipeline's responsibility.
    public static func isValidImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    @MainActor
    @discardableResult
    public func write(to pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        pasteboard.clearContents()
        var types = [pasteboardType]
        if image.tiffRepresentation != nil, pasteboardType != .tiff { types.append(.tiff) }
        pasteboard.declareTypes(types, owner: nil)
        guard pasteboard.setData(data, forType: pasteboardType) else { return false }
        if let tiff = image.tiffRepresentation, pasteboardType != .tiff {
            _ = pasteboard.setData(tiff, forType: .tiff)
        }
        return true
    }

    private var pasteboardType: NSPasteboard.PasteboardType {
        switch fileExtension {
        case "gif": NSPasteboard.PasteboardType(UTType.gif.identifier)
        case "jpg", "jpeg": NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        case "webp": NSPasteboard.PasteboardType(UTType.webP.identifier)
        case "heic": NSPasteboard.PasteboardType(UTType.heic.identifier)
        case "tif", "tiff": .tiff
        default: .png
        }
    }

    private static let pasteboardCandidates: [(type: NSPasteboard.PasteboardType, extension: String)] = [
        (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif"),
        (.png, "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
        (.tiff, "tiff"),
    ]

    private static func normalizedExtension(_ raw: String, data: Data) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if data.starts(with: Data("GIF8".utf8)) { return "gif" }
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return "png" }
        if data.starts(with: Data([0xFF, 0xD8, 0xFF])) { return "jpg" }
        if ["gif", "png", "jpg", "jpeg", "tif", "tiff", "webp", "heic"].contains(lowered) {
            return lowered == "jpeg" ? "jpg" : lowered
        }
        return "png"
    }
}
