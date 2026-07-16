import AppKit
import SwiftUI

enum HedgehogIcon {
    static let statusImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "Hedgehog", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "MemeMemo") ?? NSImage()
        }
        image.isTemplate = true
        // Fill the menu bar height like neighboring apps; width follows the
        // hedgehog's wide aspect ratio so it isn't letterboxed into a small glyph.
        let targetHeight: CGFloat = 18
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: (targetHeight * aspect).rounded(), height: targetHeight)
        return image
    }()
}
