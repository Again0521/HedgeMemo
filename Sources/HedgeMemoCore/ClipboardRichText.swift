import AppKit
import Foundation

/// Metadata stored in the history snapshot. The actual bytes live in sidecar
/// files so opening/searching clipboard history does not inflate every rich
/// representation into memory.
public struct ClipboardOriginalFormat: Codable, Hashable, Sendable {
    public let typeIdentifier: String
    public let fileName: String
    public let byteCount: Int

    public init(typeIdentifier: String, fileName: String, byteCount: Int) {
        self.typeIdentifier = typeIdentifier
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

public struct ClipboardFormatData: Equatable, Sendable {
    public let typeIdentifier: String
    public let data: Data

    public init(typeIdentifier: String, data: Data) {
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

public struct ClipboardRichTextPayload: Equatable, Sendable {
    public let plainText: String
    public let formats: [ClipboardFormatData]

    public init(plainText: String, formats: [ClipboardFormatData]) {
        self.plainText = plainText
        self.formats = formats
    }

    /// Only explicit rich-text representations are retained. Proprietary,
    /// transient and promise pasteboard types are intentionally excluded.
    @MainActor
    public static func read(from pasteboard: NSPasteboard) throws -> ClipboardRichTextPayload? {
        let declared = Set(pasteboard.types ?? [])
        guard declared.contains(.string), let text = pasteboard.string(forType: .string) else {
            return nil
        }

        var formats: [ClipboardFormatData] = []
        var totalByteCount = 0
        for type in supportedTypes where declared.contains(type) {
            guard let data = pasteboard.data(forType: type) else {
                throw ClipboardRichTextError.missingRepresentation(type.rawValue)
            }
            totalByteCount += data.count
            guard totalByteCount <= maxOriginalFormatByteCount else {
                throw ClipboardRichTextError.originalFormatsTooLarge(totalByteCount)
            }
            formats.append(ClipboardFormatData(typeIdentifier: type.rawValue, data: data))
        }
        return ClipboardRichTextPayload(plainText: text, formats: formats)
    }

    @MainActor
    public func write(to pasteboard: NSPasteboard) throws {
        let richTypes = formats.map { NSPasteboard.PasteboardType($0.typeIdentifier) }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + richTypes, owner: nil)
        guard pasteboard.setString(plainText, forType: .string) else {
            throw ClipboardRichTextError.cannotWriteRepresentation(NSPasteboard.PasteboardType.string.rawValue)
        }
        for format in formats {
            let type = NSPasteboard.PasteboardType(format.typeIdentifier)
            guard pasteboard.setData(format.data, forType: type) else {
                throw ClipboardRichTextError.cannotWriteRepresentation(format.typeIdentifier)
            }
        }
    }

    public static let maxOriginalFormatByteCount = 8_000_000

    public static func supports(typeIdentifier: String) -> Bool {
        supportedTypes.contains(NSPasteboard.PasteboardType(typeIdentifier))
    }

    private static let supportedTypes: [NSPasteboard.PasteboardType] = [
        .rtfd,
        .rtf,
        .html,
    ]
}

public enum ClipboardRichTextError: LocalizedError, Equatable {
    case originalFormatsTooLarge(Int)
    case missingRepresentation(String)
    case cannotWriteRepresentation(String)
    case unsupportedRepresentation(String)
    case unsafeStoredFileName(String)

    public var errorDescription: String? {
        switch self {
        case .originalFormatsTooLarge:
            return L10n.text("富文本格式数据过大，已跳过记录。")
        case .missingRepresentation:
            return L10n.text("无法读取剪贴板中的富文本格式。")
        case .cannotWriteRepresentation:
            return L10n.text("无法恢复剪贴板的原始格式。")
        case .unsupportedRepresentation:
            return L10n.text("剪贴板包含不受支持的格式。")
        case .unsafeStoredFileName:
            return L10n.text("剪贴板格式文件无效。")
        }
    }
}
