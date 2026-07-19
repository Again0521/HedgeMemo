import AppKit
import Foundation

@testable import HedgeMemoCore

/// Shared factories so each test file states only the fields it cares about.
enum Fixture {
    static let epoch = Date(timeIntervalSinceReferenceDate: 1_000)

    static func text(
        _ text: String,
        hash: String? = nil,
        at offset: TimeInterval = 0,
        pinned: Bool = false,
        pinnedOrder: Int? = nil,
        origin: ClipboardEntryOrigin? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(
            kind: .text,
            text: text,
            contentHash: hash ?? text,
            createdAt: epoch.addingTimeInterval(offset),
            isPinned: pinned,
            pinnedOrder: pinnedOrder,
            origin: origin
        )
    }

    static func image(hash: String, at offset: TimeInterval = 0, origin: ClipboardEntryOrigin? = nil) -> ClipboardEntry {
        ClipboardEntry(
            kind: .image,
            imageFileName: "\(hash).png",
            contentHash: hash,
            createdAt: epoch.addingTimeInterval(offset),
            origin: origin
        )
    }

    static func meme(
        _ note: String,
        hash: String,
        category: UUID? = nil,
        sortOrder: Int = 0,
        ocr: String = "",
        at offset: TimeInterval = 0
    ) -> MemeItem {
        MemeItem(
            fileName: "\(hash).png",
            contentHash: hash,
            note: note,
            ocrText: ocr,
            categoryID: category,
            sortOrder: sortOrder,
            createdAt: epoch.addingTimeInterval(offset)
        )
    }

    static func solidImage(_ shade: CGFloat, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(calibratedWhite: shade, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// A one-pixel GIF; its magic bytes let format-detection tests run without
    /// touching a real file on disk.
    static var gifBytes: Data {
        Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
    }
}
