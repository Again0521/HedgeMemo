import AppKit
import SwiftUI

enum HedgehogIcon {
    static let statusImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "Hedgehog", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "MemeMemo") ?? NSImage()
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
