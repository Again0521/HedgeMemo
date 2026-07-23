import AppKit
import SwiftUI

enum HedgehogIcon {
    private static let baseStatusImage: NSImage = {
        let resourceURL = Bundle.main.url(forResource: "Hedgehog", withExtension: "png")
            ?? Bundle.main.url(forResource: "Hedgehog", withExtension: "svg")
        guard let resourceURL,
              let image = NSImage(contentsOf: resourceURL) else {
            return NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "HedgeMemo") ?? NSImage()
        }
        // Preserve the supplied artwork's dark body, white face, curved belly,
        // foot, and soft baseline instead of flattening it into a template glyph.
        image.isTemplate = false
        image.resizingMode = .stretch
        let targetHeight: CGFloat = 18
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: (targetHeight * aspect).rounded(), height: targetHeight)
        return image
    }()

    static func statusImage(hasUpdate: Bool) -> NSImage {
        guard hasUpdate else { return baseStatusImage }
        let size = baseStatusImage.size
        let composed = NSImage(size: size, flipped: false) { rect in
            baseStatusImage.draw(in: rect)
            guard let arrow = NSImage(
                systemSymbolName: "arrow.up",
                accessibilityDescription: "有新版本"
            )?.withSymbolConfiguration(.init(pointSize: 7, weight: .heavy)) else { return true }
            let arrowSize = NSSize(width: 7, height: 7)
            let arrowRect = NSRect(
                x: rect.maxX - arrowSize.width,
                y: rect.maxY - arrowSize.height,
                width: arrowSize.width,
                height: arrowSize.height
            )
            NSColor.systemBlue.set()
            arrow.draw(in: arrowRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        composed.isTemplate = false
        return composed
    }
}
