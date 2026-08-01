import AppKit
import SwiftUI

/// Shared visual vocabulary for every custom panel.  The panel window owns the
/// glass material (through `PanelMaterialHost`); controls only use semantic
/// system states on top of it.  In particular, never add an opaque color or a
/// hover-time material behind an entire panel — that is what made the old
/// clipboard, preview, and settings surfaces look like different products.
enum NativePanelMetrics {
    static let cornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 8
    static let controlHeight: CGFloat = 28
    static let horizontalPadding: CGFloat = 12
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

/// Compact search field shared by the meme and clipboard panels.
struct PanelSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            PanelSearchTextInput(placeholder: placeholder, text: $text)
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
        .padding(.horizontal, 9)
        .frame(height: NativePanelMetrics.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: NativePanelMetrics.compactCornerRadius, style: .continuous)
                .fill(.quaternary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NativePanelMetrics.compactCornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.72), lineWidth: 1)
        )
    }
}

/// Creates the panel search editor with remote completion disabled before the
/// field ever joins a window. Applying the same settings after SwiftUI has
/// materialized its `TextField` is too late on macOS 27: SafariPlatformSupport
/// may already have attached an out-of-process completion view.
private struct PanelSearchTextInput: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> CrashSafePanelTextField {
        let field = CrashSafePanelTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: CrashSafePanelTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        field.disableRemoteInputServices()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? CrashSafePanelTextField else { return }
            field.disableRemoteInputServices()
            if let editor = field.currentEditor() as? NSTextView {
                TextCompletionCrashGuard.disableRemoteCompletion(for: editor)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class CrashSafePanelTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        if #available(macOS 15.2, *) { allowsWritingTools = false }
        disableRemoteInputServices()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        disableRemoteInputServices()
    }

    func disableRemoteInputServices() {
        isAutomaticTextCompletionEnabled = false
        contentType = nil
        if let editor = currentEditor() as? NSTextView {
            TextCompletionCrashGuard.disableRemoteCompletion(for: editor)
        }
    }
}

/// Native borderless toolbar button.  We deliberately leave hover rendering to
/// AppKit instead of inserting a custom white/gray fill; a manual hover layer
/// was the source of the clipboard and preview material flashes.
struct HoverIconButton: View {
    let systemImage: String
    var tint: Color = .primary
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
