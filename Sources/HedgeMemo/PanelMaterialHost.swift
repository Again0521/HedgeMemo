import AppKit
import SwiftUI

/// Native material host intentionally kept to the same three layers used by
/// Maccy's floating popup: standard `NSHostingView`, SwiftUI `ZStack`, and the
/// system glass background.  There is no custom NSView subclass, compositing
/// filter, opacity, tint, hover state, or shadow view in this type.
@MainActor
enum PanelMaterialHost {
    static func make(cornerRadius: CGFloat, usesWindowMaterial: Bool = true) -> NSView {
        let host = NSHostingView<AnyView>(
            rootView: rootView(for: AnyView(EmptyView()), usesWindowMaterial: usesWindowMaterial)
        )
        host.wantsLayer = true
        host.layer?.cornerRadius = cornerRadius
        host.layer?.cornerCurve = .continuous
        // The system glass view is hosted inside a transparent NSPanel.  The
        // host itself must clip to the same continuous corner, otherwise the
        // panel compositor can leave a rectangular transparent backing store
        // visible below the rounded SwiftUI card.  This does not touch the
        // NSPanel's native outside shadow.
        host.layer?.masksToBounds = true
        return host
    }

    static func install<Content: View>(
        _ content: Content,
        in window: NSWindow,
        cornerRadius: CGFloat,
        usesWindowMaterial: Bool = true
    ) {
        let host = make(cornerRadius: cornerRadius, usesWindowMaterial: usesWindowMaterial)
        replace(content, in: host, usesWindowMaterial: usesWindowMaterial)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }

    static func replace<Content: View>(
        _ content: Content,
        in root: NSView,
        usesWindowMaterial: Bool = true
    ) {
        guard let host = root as? NSHostingView<AnyView> else { return }
        host.rootView = rootView(for: AnyView(content), usesWindowMaterial: usesWindowMaterial)
    }

    private static func rootView(for content: AnyView, usesWindowMaterial: Bool) -> AnyView {
        AnyView(
            LanguageSurface {
                ZStack {
                    if usesWindowMaterial {
                        AdjustablePanelBackground()
                    }
                    content
                }
                .ignoresSafeArea()
            }
        )
    }
}

/// A clipped card surface for multiple pieces of content inside one key panel.
/// Its backing is the exact same native glass view as the window surface, not a
/// color overlay. Separation from the desktop is deliberately supplied by
/// the owning NSPanel's native shadow, exactly as Maccy's FloatingPanel does.
struct SystemGlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background(AdjustablePanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct AdjustablePanelBackground: View {
    @AppStorage(AppPreferences.interfaceOpacityKey)
    private var interfaceOpacity = AppPreferences.defaultInterfaceOpacity

    private var level: Double {
        AppPreferences.clampedInterfaceOpacity(interfaceOpacity)
    }

    var body: some View {
        Group {
            if level >= 0.999 {
                // At 100%, remove the glass compositor instead of merely
                // covering it: this setting explicitly disables transparency.
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    SystemGlassSurface()
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(AppPreferences.opaqueBackingAlpha(for: level))
                }
            }
        }
    }
}

private struct SystemGlassSurface: View {
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                MaccyGlassBackground()
            } else {
                MaccyPopoverBackground()
            }
        }
    }
}

/// The macOS 26 branch is deliberately the same native primitive Maccy hosts
/// behind its whole FloatingPanel.  It belongs at the panel root exactly once:
/// list and SlideoutView are then two pieces of content over one glass sample.
@available(macOS 26.0, *)
private struct MaccyGlassBackground: NSViewRepresentable {
    // Create the backing view inside makeNSView, not as a stored property.
    // SwiftUI recreates this representable value on every parent body pass; an
    // eagerly-stored NSView allocated a fresh glass view on each of those passes
    // only to discard it, since SwiftUI reuses the one it already hosts. The
    // hosted view and its configuration are unchanged.
    func makeNSView(context: Context) -> NSGlassEffectView { NSGlassEffectView() }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = .regular
    }
}

/// Equivalent to Maccy's pre-Liquid-Glass VisualEffectView fallback.
private struct MaccyPopoverBackground: NSViewRepresentable {
    // Same rationale as MaccyGlassBackground: build the view lazily so repeated
    // body passes don't allocate throwaway effect views.
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}
