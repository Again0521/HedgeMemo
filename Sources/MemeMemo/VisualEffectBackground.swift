import AppKit
import SwiftUI

/// Native vibrancy backdrop, matching the look of system status bar popovers.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

extension View {
    /// Applies the translucent native backdrop used by every MemeMemo popup.
    func nativePopupBackground(cornerRadius: CGFloat = 0) -> some View {
        background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension NSPanel {
    /// Strips the opaque window chrome so the SwiftUI vibrancy backdrop is what the user sees.
    func applyTranslucentChrome(cornerRadius: CGFloat = 12) {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = cornerRadius
        contentView?.layer?.cornerCurve = .continuous
        contentView?.layer?.masksToBounds = true
    }
}
