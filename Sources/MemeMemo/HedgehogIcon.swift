import AppKit
import SwiftUI

enum HedgehogIcon {
    static let statusImage: NSImage = {
        let resourceURL = Bundle.main.url(forResource: "Hedgehog", withExtension: "png")
            ?? Bundle.main.url(forResource: "Hedgehog", withExtension: "svg")
        guard let resourceURL,
              let image = NSImage(contentsOf: resourceURL) else {
            return NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "MemeMemo") ?? NSImage()
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
}
