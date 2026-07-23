import AppKit
import SwiftUI

enum HedgehogIcon {
    /// The menu-bar artwork is a single-color hedgehog silhouette with a
    /// transparent face cutout (see `Resources/Hedgehog.svg`/`.png`: opaque body
    /// pixels, alpha-0 face). Marking it a template lets AppKit tint it with the
    /// menu bar's own icon color, so it turns light on a dark menu bar and dark
    /// on a light one — matching every other status item instead of staying a
    /// fixed dark shape. The face cutout survives because it is transparency,
    /// not white fill.
    private static let baseStatusImage: NSImage = {
        let resourceURL = Bundle.main.url(forResource: "Hedgehog", withExtension: "png")
            ?? Bundle.main.url(forResource: "Hedgehog", withExtension: "svg")
        guard let resourceURL,
              let image = NSImage(contentsOf: resourceURL) else {
            let fallback = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "HedgeMemo") ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        image.resizingMode = .stretch
        let targetHeight: CGFloat = 18
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: (targetHeight * aspect).rounded(), height: targetHeight)
        image.isTemplate = true
        return image
    }()

    static func statusImage(hasUpdate: Bool) -> NSImage {
        guard hasUpdate else { return baseStatusImage }
        let size = baseStatusImage.size
        // The update badge must keep a colored hint, so this composite cannot be
        // a template. Tint the silhouette with the dynamic `labelColor` (which
        // AppKit re-resolves per appearance when the button redraws) so it still
        // tracks the menu bar, then stamp a colored up-arrow on top.
        let composed = NSImage(size: size, flipped: false) { rect in
            baseStatusImage.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let arrowConfig = NSImage.SymbolConfiguration(pointSize: 7, weight: .heavy)
                .applying(.init(paletteColors: [.systemBlue]))
            guard let arrow = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "有新版本")?
                .withSymbolConfiguration(arrowConfig) else { return true }
            let arrowSize = NSSize(width: 7, height: 7)
            let arrowRect = NSRect(
                x: rect.maxX - arrowSize.width,
                y: rect.maxY - arrowSize.height,
                width: arrowSize.width,
                height: arrowSize.height
            )
            arrow.draw(in: arrowRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        composed.isTemplate = false
        return composed
    }
}
