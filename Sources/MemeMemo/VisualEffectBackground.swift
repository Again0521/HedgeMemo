import AppKit
import SwiftUI

@MainActor
enum SystemSurface {
    /// Every floating surface uses NSVisualEffectView, never NSGlassEffectView.
    /// The glass view lays out its `contentView` itself: when the SwiftUI
    /// content is taller than the window it bottom-aligns and the top of the
    /// panel (search field, category bar) gets clipped away. The visual-effect
    /// pipeline keeps the hosting view frame-locked to the window, which is
    /// predictable and testable.
    static func container(
        material: NSVisualEffectView.Material,
        cornerRadius: CGFloat? = nil
    ) -> NSView {
        let container = SystemSurfaceView()
        container.autoresizingMask = [.width, .height]

        let backdrop = NSVisualEffectView()
        backdrop.material = material
        backdrop.blendingMode = .behindWindow
        // Forced active: the detail card is an ignores-mouse child window that
        // can never become key, so `.followsWindowActiveState` rendered it in
        // the inactive appearance — a visibly different material from the key
        // main panel. `.active` gives every surface the same dense frost.
        backdrop.state = .active
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        if let cornerRadius {
            backdrop.maskImage = .cornerMask(radius: cornerRadius)
        }
        container.backdrop = backdrop
        container.addSubview(backdrop)
        return container
    }

    static func install<Content: View>(
        _ content: Content,
        in window: NSWindow,
        material: NSVisualEffectView.Material,
        cornerRadius: CGFloat? = nil
    ) {
        let surface = container(material: material, cornerRadius: cornerRadius)
        replaceContent(content, in: surface)
        window.contentView = surface
    }

    static func replaceContent<Content: View>(_ content: Content, in container: NSView) {
        let hosting = TransparentHostingView(rootView: content)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        if let surface = container as? SystemSurfaceView {
            surface.hostingView?.removeFromSuperview()
        } else {
            container.subviews.forEach { $0.removeFromSuperview() }
        }
        container.addSubview(hosting)
        (container as? SystemSurfaceView)?.hostingView = hosting
    }

    /// Introspection for the layout/material self-check.
    static func backdropConfiguration(of view: NSView?) -> (material: NSVisualEffectView.Material, state: NSVisualEffectView.State)? {
        guard let surface = view as? SystemSurfaceView, let backdrop = surface.backdrop else { return nil }
        return (backdrop.material, backdrop.state)
    }

    /// Frame of the hosted SwiftUI content, for verifying it stays aligned
    /// with the window instead of overflowing past the top edge.
    static func hostingFrame(of view: NSView?) -> NSRect? {
        (view as? SystemSurfaceView)?.hostingView?.frame
    }
}

/// `NSHostingView` may otherwise report itself as opaque and let AppKit draw a
/// rectangular window background outside a SwiftUI glass shape. Floating
/// panels need a genuinely transparent bridge so their rounded bottom corners
/// remain visible over light content as well as wallpaper.
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

private final class SystemSurfaceView: NSView {
    weak var backdrop: NSVisualEffectView?
    weak var hostingView: NSView?
}

/// NSImageView is used instead of SwiftUI.Image so animated GIF representations
/// keep playing in previews while static formats use the same aspect-fit layout.
struct AnimatedImageFileView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AspectFitImageView {
        let view = AspectFitImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.image = NSImage(contentsOf: url)
        context.coordinator.url = url
        return view
    }

    func updateNSView(_ view: AspectFitImageView, context: Context) {
        if context.coordinator.url != url {
            view.image = NSImage(contentsOf: url)
            context.coordinator.url = url
        }
        view.animates = true
    }

    final class Coordinator {
        var url: URL?
    }

    final class AspectFitImageView: NSImageView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension NSImage {
    /// Stretchable rounded-corner mask. Behind-window blur is shaped by the
    /// window server, so rounding must go through `NSVisualEffectView.maskImage`;
    /// a CALayer cornerRadius clips the tint but leaves the backdrop square.
    static func cornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Compact search field shared by the meme and clipboard panels.
struct PanelSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

/// Borderless icon button that shows a soft rounded highlight on hover,
/// like toolbar buttons in system popovers.
struct HoverIconButton: View {
    let systemImage: String
    var tint: Color = .primary
    var help: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Capsule chip used for category filters.
struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(Color.accentColor)
                                : isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
