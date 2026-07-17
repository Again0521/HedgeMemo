import AppKit
import SwiftUI

@MainActor
enum SystemSurface {
    enum BackdropKind: Equatable {
        case glass
        case vibrancy(NSVisualEffectView.Material, NSVisualEffectView.State)
    }

    /// One native contextual-popover recipe shared by every custom surface.
    ///
    /// The clipboard is a utility panel, not a toolbar control.  AppKit's
    /// `NSVisualEffectView(.popover, .behindWindow)` is the same stable
    /// backing used by native contextual popovers (and by Maccy's floating
    /// panel).  `NSGlassEffectView` deliberately changes emphasis as an
    /// auxiliary window becomes key, which made the whole surface flash white
    /// whenever the pointer crossed into it.  Keeping this one AppKit material
    /// for every surface makes hover, focus and preview presentation identical.
    static func container(
        material: NSVisualEffectView.Material,
        cornerRadius: CGFloat? = nil
    ) -> NSView {
        let container = SystemSurfaceView()
        container.autoresizingMask = [.width, .height]
        if let cornerRadius {
            container.wantsLayer = true
            container.layer?.cornerRadius = cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
        }

        let backdrop: NSView
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        // Never follow the host window's key state.  Detail and main surfaces
        // must remain visually identical whether the search field is focused,
        // an entry is hovered, or a preview is visible.
        effect.state = .active
        if let cornerRadius {
            effect.maskImage = .cornerMask(radius: cornerRadius)
        }
        backdrop = effect
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.backdrop = backdrop
        container.addSubview(backdrop)
        return container
    }

    /// Introspection for the self-check.
    static func backdropKind(of view: NSView?) -> BackdropKind? {
        guard let surface = view as? SystemSurfaceView, let backdrop = surface.backdrop else { return nil }
        if let effect = backdrop as? NSVisualEffectView { return .vibrancy(effect.material, effect.state) }
        return nil
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
            container.addSubview(hosting)
            surface.hostingView = hosting
        } else {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(hosting)
        }
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
    weak var backdrop: NSView?
    weak var hostingView: NSView?
}

/// Shadow-only companion for a floating glass card. The opaque fill is fully
/// covered by the card above it; only the rounded shadow is visible. This lets
/// two cards in one transparent host keep the native separation shadow without
/// producing a rectangular/L-shaped shadow around their combined window.
final class RoundedCardShadowView: NSView {
    static let shadowInset: CGFloat = 18
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    func frame(for cardFrame: NSRect) -> NSRect {
        cardFrame.insetBy(dx: -Self.shadowInset, dy: -Self.shadowInset)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill()
        let cardRect = bounds.insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
        NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        context.restoreGState()
    }
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
