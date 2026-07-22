import AppKit
import Combine
import HedgeMemoCore
import SwiftUI

/// Owns the long-lived desktop notes created from pinned clipboard entries.
/// SwiftUI owns each note's presentation state; AppKit is used only for the
/// window lifecycle and the normal/floating level switch that SwiftUI scenes
/// cannot express per dynamically-created note.
@MainActor
final class PinnedClipboardWindowsController {
    private let store: ClipboardHistoryStore
    private var windows: [UUID: PinnedClipboardWindow] = [:]
    private var entriesObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?

    init(store: ClipboardHistoryStore) {
        self.store = store
        entriesObserver = store.$entries
            .dropFirst()
            .sink { [weak self] entries in
                self?.synchronize(with: entries)
            }

        settingsObserver = store.$settings
            .dropFirst()
            .sink { [weak self] settings in
                self?.refreshCodeTheme(settings.resolvedCodeHighlightTheme)
            }

        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--preview-") }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.synchronize(with: self.store.entries)
        }
    }

    func toggle(_ entry: ClipboardEntry) {
        store.toggleDesktopPinned(id: entry.id)
        synchronize(with: store.entries)
    }

    private func unpin(id: UUID) {
        if store.entries.first(where: { $0.id == id })?.isDesktopPinned == true {
            store.toggleDesktopPinned(id: id)
        }
        synchronize(with: store.entries)
    }

    /// Persists an in-place edit made from a note's own edit mode. The note
    /// window updates its own displayed text immediately on save (see
    /// `PinnedClipboardWindow.saveText`) — `synchronize` only opens windows
    /// for newly-pinned entries, so it does not refresh an already-open one.
    private func saveText(id: UUID, text: String) {
        store.updateText(id: id, text: text)
    }

    private func synchronize(with entries: [ClipboardEntry]) {
        let pinnedEntries = entries.filter { $0.isDesktopPinned == true }
        let pinned = Dictionary(uniqueKeysWithValues: pinnedEntries.map { ($0.id, $0) })

        let staleWindowIDs = windows.keys.filter { pinned[$0] == nil }
        for id in staleWindowIDs {
            windows.removeValue(forKey: id)?.close()
        }

        for entry in pinnedEntries.sorted(by: { $0.updatedAt < $1.updatedAt }) where windows[entry.id] == nil {
            let note = PinnedClipboardWindow(
                entry: entry,
                imageURL: store.imageURL(for: entry),
                codeHighlightTheme: store.settings.resolvedCodeHighlightTheme,
                cascadeIndex: windows.count,
                onUnpin: { [weak self] id in self?.unpin(id: id) },
                onSaveText: { [weak self] id, text in self?.saveText(id: id, text: text) }
            )
            windows[entry.id] = note
            note.show()
        }
    }

    private func refreshCodeTheme(_ theme: CodeHighlightTheme) {
        windows.values.forEach { $0.updateCodeHighlightTheme(theme) }
    }
}

@MainActor
private final class PinnedClipboardWindow {
    private let panel: PinnedClipboardPanel
    private let model: PinnedClipboardWindowModel
    private let entry: ClipboardEntry
    private let imageURL: URL?
    private let onUnpin: (UUID) -> Void
    private let onSaveText: (UUID, String) -> Void
    private var codeHighlightTheme: CodeHighlightTheme

    init(
        entry: ClipboardEntry,
        imageURL: URL?,
        codeHighlightTheme: CodeHighlightTheme,
        cascadeIndex: Int,
        onUnpin: @escaping (UUID) -> Void,
        onSaveText: @escaping (UUID, String) -> Void
    ) {
        self.entry = entry
        self.imageURL = imageURL
        self.onUnpin = onUnpin
        self.onSaveText = onSaveText
        self.codeHighlightTheme = codeHighlightTheme
        // The note's displayed text starts as the entry's own text, then
        // becomes independently editable — `entry` stays the immutable
        // snapshot the window was built from (see `saveText` below).
        self.model = PinnedClipboardWindowModel(initialText: entry.text ?? "")
        let size = PinnedClipboardWindowLayout.windowSize(for: entry, imageURL: imageURL)
        let frame = PinnedClipboardWindowLayout.initialFrame(size: size, cascadeIndex: cascadeIndex)
        let panel = PinnedClipboardPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Desktop notes are separate app surfaces. Keep the normal native
        // outside shadow, while PanelMaterialHost owns the matching rounded
        // material inside the panel.
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 240, height: 150)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrame(frame, display: false)

        let content = noteContent()
        PanelMaterialHost.install(content, in: panel, cornerRadius: 14)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func updateCodeHighlightTheme(_ theme: CodeHighlightTheme) {
        guard codeHighlightTheme != theme, let root = panel.contentView else { return }
        codeHighlightTheme = theme
        PanelMaterialHost.replace(noteContent(), in: root)
    }

    private func noteContent() -> PinnedClipboardNoteView {
        PinnedClipboardNoteView(
            entry: entry,
            imageURL: imageURL,
            codeHighlightTheme: codeHighlightTheme,
            model: model,
            onToggleAlwaysOnTop: { [weak self] in self?.toggleAlwaysOnTop() },
            onUnpin: { [onUnpin, entry] in onUnpin(entry.id) },
            onSaveText: { [weak self] text in self?.saveText(text) }
        )
    }

    private func toggleAlwaysOnTop() {
        model.isAlwaysOnTop.toggle()
        panel.level = model.isAlwaysOnTop ? .floating : .normal
        panel.orderFrontRegardless()
    }

    private func saveText(_ text: String) {
        model.displayedText = text
        onSaveText(entry.id, text)
    }
}

private final class PinnedClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PinnedClipboardWindowModel: ObservableObject {
    @Published var isAlwaysOnTop = false
    @Published var isEditing = false
    @Published var draftText: String
    /// The note's own copy of its text, independent of the immutable `entry`
    /// snapshot the window was built from. Editing updates only this, so the
    /// note reflects a save immediately without needing the window rebuilt.
    @Published var displayedText: String

    init(initialText: String) {
        self.draftText = initialText
        self.displayedText = initialText
    }
}

private struct PinnedClipboardNoteView: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let codeHighlightTheme: CodeHighlightTheme
    @ObservedObject var model: PinnedClipboardWindowModel
    let onToggleAlwaysOnTop: () -> Void
    let onUnpin: () -> Void
    let onSaveText: (String) -> Void

    @FocusState private var isEditorFocused: Bool
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        // A plain SwiftUI window with no key-event monitor of its own, so
        // these shortcuts only need to be registered — nothing here can steal
        // keystrokes away from the TextEditor the way the clipboard panel's
        // window-wide monitor would. ⌘E enters editing (no on-screen hint,
        // matching the request); ⌘S saves, Esc cancels.
        .background(
            Group {
                if model.isEditing {
                    Button("保存", action: saveEditing)
                        .keyboardShortcut("s", modifiers: .command)
                    Button("取消", action: cancelEditing)
                        .keyboardShortcut(.cancelAction)
                } else if entry.kind == .text {
                    Button("编辑", action: beginEditing)
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
        .onChange(of: model.isEditing) { _, editing in
            guard editing else { return }
            DispatchQueue.main.async { isEditorFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.contentCategory.systemImage)
                .foregroundStyle(.secondary)
            Text(entry.sourceApp ?? "剪贴板便签")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // Only a text-kind note has anything to edit; an image note has no
            // text body. Placed to the left of "保持最前" per the requested layout.
            // The button toggles: a first click enters editing, a second click
            // finishes and saves.
            if entry.kind == .text {
                Button(action: toggleEditing) {
                    Image(systemName: model.isEditing ? "checkmark" : "pencil")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isEditing ? Color.accentColor : Color.secondary)
                .help(model.isEditing ? "完成编辑" : "编辑")
                .accessibilityLabel(model.isEditing ? "完成编辑" : "编辑")
            }
            Button(action: onToggleAlwaysOnTop) {
                Image(systemName: model.isAlwaysOnTop ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isAlwaysOnTop ? Color.accentColor : Color.secondary)
            .help(model.isAlwaysOnTop ? "取消保持最前" : "保持最前")
            .accessibilityLabel(model.isAlwaysOnTop ? "取消保持最前" : "保持最前")

            Button(action: onUnpin) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("取消固定")
            .accessibilityLabel("取消固定")
        }
        .padding(.horizontal, 12)
        .frame(height: PinnedClipboardWindowLayout.headerHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditing, entry.contentCategory == .code {
            CodeTextEditor(
                text: $model.draftText,
                theme: codeHighlightTheme,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                showsScrollIndicators: showsScrollIndicators,
                onCancel: cancelEditing
            )
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isEditing {
            TextEditor(text: $model.draftText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focused($isEditorFocused)
        } else if entry.kind == .image, let imageURL {
            AnimatedImageFileView(url: imageURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ScrollView(.vertical) {
                Group {
                    if entry.contentCategory == .code {
                        Text(CodeHighlighter.highlight(model.displayedText, theme: codeHighlightTheme))
                    } else {
                        Text(model.displayedText.isEmpty ? entry.previewText : model.displayedText)
                    }
                }
                .font(entry.contentCategory == .code
                      ? .system(size: 12, design: .monospaced)
                      : .system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The header pencil/checkmark toggles editing: enter on a first click,
    /// finish and save on a second.
    private func toggleEditing() {
        if model.isEditing { saveEditing() } else { beginEditing() }
    }

    private func beginEditing() {
        model.draftText = model.displayedText
        withAnimation(.easeInOut(duration: 0.18)) { model.isEditing = true }
    }

    /// Saving blank text would leave a pointless empty note, so an
    /// all-whitespace draft quietly discards instead of persisting.
    private func saveEditing() {
        let text = model.draftText
        withAnimation(.easeInOut(duration: 0.18)) { model.isEditing = false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSaveText(text)
    }

    private func cancelEditing() {
        withAnimation(.easeInOut(duration: 0.18)) { model.isEditing = false }
    }
}

private enum PinnedClipboardWindowLayout {
    static let headerHeight: CGFloat = 38
    private static let contentPadding: CGFloat = 24
    private static let minimumWidth: CGFloat = 240
    private static let maximumWidth: CGFloat = 520
    private static let maximumImageSide: CGFloat = 420
    private static let maximumTextLines = 20

    static func windowSize(for entry: ClipboardEntry, imageURL: URL?) -> NSSize {
        let contentSize = measuredContentSize(for: entry, imageURL: imageURL)
        return NSSize(
            width: contentSize.width + contentPadding,
            height: headerHeight + contentSize.height + contentPadding
        )
    }

    static func initialFrame(size: NSSize, cascadeIndex: Int) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let offset = CGFloat(cascadeIndex % 8) * 22
        let desiredX = mouse.x + 18 + offset
        let desiredY = mouse.y - size.height / 2 - offset
        let x = min(max(desiredX, visible.minX + 12), visible.maxX - size.width - 12)
        let y = min(max(desiredY, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func measuredContentSize(for entry: ClipboardEntry, imageURL: URL?) -> NSSize {
        if entry.kind == .image, let imageURL, let pixels = imagePixelSize(of: imageURL) {
            guard pixels.width > 0, pixels.height > 0 else {
                return NSSize(width: 280, height: 220)
            }
            let scale = min(maximumImageSide / pixels.width, maximumImageSide / pixels.height, 1)
            return NSSize(
                width: max(minimumWidth - contentPadding, pixels.width * scale),
                height: max(120, pixels.height * scale)
            )
        }

        let text = entry.text ?? entry.previewText
        let font = entry.contentCategory == .code
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        let naturalLineWidth = text.components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let windowWidth = min(maximumWidth, max(minimumWidth, naturalLineWidth + contentPadding + 8))
        let textWidth = windowWidth - contentPadding
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let visualLines = max(1, Int(ceil(bounds.height / lineHeight)))
        let visibleLines = min(maximumTextLines, visualLines)
        return NSSize(width: textWidth, height: CGFloat(visibleLines) * lineHeight + 2)
    }
}
