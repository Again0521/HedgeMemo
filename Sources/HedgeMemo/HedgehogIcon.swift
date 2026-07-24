import AppKit
import HedgeMemoCore
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
        // Keep the whole badge a template so it stays exactly as adaptive as the
        // plain icon — a colored (e.g. blue) arrow would follow the app's own
        // appearance, not the menu bar, and could show a dark hedgehog against
        // light icons on a dark bar, which is the very thing being fixed. The
        // up-arrow shape (plus the tooltip) still signals an available update.
        let composed = NSImage(size: size, flipped: false) { rect in
            baseStatusImage.draw(in: rect)
            guard let arrow = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: L10n.text("有新版本"))?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .heavy)) else { return true }
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
        composed.isTemplate = true
        return composed
    }
}
