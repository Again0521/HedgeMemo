import AppKit
import Combine
import MemeMemoCore
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController: NSObject {
    private let store: ClipboardHistoryStore
    private var panel: NSPanel?
    private var hoverCard: NSPanel?
    private var resignKeyObserver: NSObjectProtocol?

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    func toggle() {
        if panel?.isVisible == true { hide() }
        else { show() }
    }

    func hide() {
        hideHoverCard()
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let content = ClipboardHistoryPanelView(
            store: store,
            onDone: { [weak self] in self?.hide() },
            onContentChange: { [weak self] contentHeight in
                self?.resize(contentHeight: contentHeight, animate: true)
            },
            onDetailEntry: { [weak self] entry in
                self?.updateHoverCard(entry: entry)
            }
        )
        if let effectView = panel.contentView as? NSVisualEffectView {
            effectView.subviews.forEach { $0.removeFromSuperview() }
            let hosting = NSHostingView(rootView: content)
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = effectView.bounds
            effectView.addSubview(hosting)
        }
        let key = store.settings.activeCategoryKey
        resize(
            contentHeight: ClipboardPanelLayout.contentHeight(for: store.orderedEntries(key: key), key: key),
            animate: false
        )
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: ClipboardPanelLayout.panelWidth, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = Self.makeVibrancyView(cornerRadius: 16)

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        return panel
    }

    static func makeVibrancyView(cornerRadius: CGFloat) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        // maskImage (not a layer mask) so the window server rounds the blur itself.
        effectView.maskImage = .cornerMask(radius: cornerRadius)
        return effectView
    }

    /// The screen the panel lives on, falling back to wherever the mouse is.
    private var activeScreen: NSScreen? {
        if let screen = panel?.screen { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func resize(contentHeight: CGFloat, animate: Bool) {
        guard let panel else { return }
        let visibleFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let height = ClipboardPanelLayout.panelHeight(
            contentHeight: contentHeight,
            availableHeight: visibleFrame.height - 24
        )
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = max(top - height, visibleFrame.minY + 12)
        frame.size.width = ClipboardPanelLayout.panelWidth
        panel.setFrame(frame, display: true, animate: animate && panel.isVisible)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let size = panel.frame.size
        let origin = NSPoint(
            x: min(max(mouse.x - size.width / 2, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12),
            y: min(max(mouse.y - 24 - size.height, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Detail card

    private func updateHoverCard(entry: ClipboardEntry?) {
        guard let entry, let panel, panel.isVisible else {
            hideHoverCard()
            return
        }
        let card = hoverCard ?? makeHoverCard()
        hoverCard = card

        let content = ClipboardDetailCard(entry: entry, imageURL: store.imageURL(for: entry))
        let hosting = NSHostingView(rootView: content)
        var size = hosting.fittingSize
        let visibleFrame = activeScreen?.visibleFrame ?? panel.frame
        size.height = min(size.height, visibleFrame.height * 0.7)
        if let effectView = card.contentView as? NSVisualEffectView {
            effectView.subviews.forEach { $0.removeFromSuperview() }
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]
            effectView.addSubview(hosting)
        }

        let mouse = NSEvent.mouseLocation
        var x = panel.frame.minX - size.width - 10
        if x < visibleFrame.minX + 8 {
            x = panel.frame.maxX + 10
        }
        let y = min(
            max(mouse.y - size.height / 2, visibleFrame.minY + 8),
            visibleFrame.maxY - size.height - 8
        )
        card.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if card.parent == nil {
            panel.addChildWindow(card, ordered: .above)
        }
        card.orderFront(nil)
    }

    private func makeHoverCard() -> NSPanel {
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = true
        card.ignoresMouseEvents = true
        card.isReleasedWhenClosed = false
        card.level = .floating
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        card.contentView = Self.makeVibrancyView(cornerRadius: 12)
        return card
    }

    private func hideHoverCard() {
        guard let hoverCard else { return }
        hoverCard.parent?.removeChildWindow(hoverCard)
        hoverCard.orderOut(nil)
    }
}

/// Borderless panels refuse key status by default; the search field needs it.
private final class KeyableClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Detail card content

private struct ClipboardDetailCard: View {
    let entry: ClipboardEntry
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                detailRow("来源", entry.sourceApp ?? "未知")
                detailRow("类型", entry.contentCategory.displayName)
                detailRow("收录时间", entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("上次使用", entry.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "还未使用")
                detailRow("使用次数", "\(entry.useCount ?? 0) 次")
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("按 ⏎ 复制。按 ⌫ 删除。")
                Text(entry.isPinned ? "按 ⌘P 取消置顶。" : "按 ⌘P 置顶。")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 264, alignment: .leading)
    }

    @ViewBuilder
    private var preview: some View {
        if entry.kind == .image, let imageURL, let image = NSImage(contentsOf: imageURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if entry.contentCategory == .code {
            Text(CodeHighlighter.highlight(entry.text ?? ""))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(30)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.text ?? entry.previewText)
                .font(.system(size: 12))
                .lineLimit(30)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
    }
}

// MARK: - Panel content

struct ClipboardHistoryPanelView: View {
    @ObservedObject var store: ClipboardHistoryStore
    let onDone: () -> Void
    let onContentChange: (CGFloat) -> Void
    let onDetailEntry: (ClipboardEntry?) -> Void

    @State private var query = ""
    @State private var selectedID: UUID?

    private var activeKey: ClipboardCategoryKey { store.settings.activeCategoryKey }
    private var entries: [ClipboardEntry] { store.orderedEntries(query: query, key: activeKey) }

    var body: some View {
        VStack(spacing: ClipboardPanelLayout.sectionSpacing) {
            PanelSearchField(placeholder: "搜索剪贴板", text: $query)
                .frame(height: ClipboardPanelLayout.headerHeight)
            categoryBar
                .frame(height: ClipboardPanelLayout.segmentedHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    content
                }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                    onDetailEntry(entries.first(where: { $0.id == id }))
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
                }
            }
        }
        .padding(ClipboardPanelLayout.outerPadding)
        .frame(width: ClipboardPanelLayout.panelWidth)
        .background(KeyCaptureView { event in handleKey(event) }.frame(width: 0, height: 0))
        .onAppear {
            ensureSelection()
            reportContentHeight()
        }
        .onChange(of: query) { _, _ in selectionAndSizeChanged() }
        .onChange(of: store.settings.lastCategory) { _, _ in selectionAndSizeChanged() }
        .onChange(of: store.entries) { _, _ in selectionAndSizeChanged() }
        .onDisappear { onDetailEntry(nil) }
    }

    private var emptyTitle: String {
        switch activeKey {
        case .builtin(let category):
            switch category {
            case .image: "没有图片记录"
            case .text: "没有文本记录"
            case .code: "没有代码记录"
            case .link: "没有链接记录"
            }
        case .custom:
            "没有匹配的记录"
        }
    }

    private var emptySymbol: String {
        switch activeKey {
        case .builtin(let category): category.systemImage
        case .custom: "tag"
        }
    }

    private func selectionAndSizeChanged() {
        ensureSelection()
        reportContentHeight()
    }

    private func reportContentHeight() {
        onContentChange(ClipboardPanelLayout.contentHeight(for: entries, key: activeKey))
    }

    private func title(for key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): category.displayName
        case .custom(let id): store.settings.customCategory(id: id)?.name ?? "自定义"
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.settings.orderedCategoryKeys, id: \.storageValue) { key in
                    CategoryChip(title: title(for: key), isSelected: activeKey == key) {
                        store.settings.activeCategoryKey = key
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch activeKey {
        case .builtin(.image):
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(ClipboardPanelLayout.imageCellSide), spacing: ClipboardPanelLayout.imageCellSpacing),
                    count: ClipboardPanelLayout.imageColumns
                ),
                alignment: .leading,
                spacing: ClipboardPanelLayout.imageCellSpacing
            ) {
                ForEach(entries) { entry in
                    ImageEntryCell(
                        entry: entry,
                        imageURL: store.imageURL(for: entry),
                        isSelected: selectedID == entry.id
                    )
                    .id(entry.id)
                    .onTapGesture { copy(entry) }
                    .onHover { if $0 { selectedID = entry.id } }
                    .contextMenu { entryMenu(entry) }
                }
            }
        default:
            LazyVStack(spacing: ClipboardPanelLayout.listSpacing) {
                ForEach(entries) { entry in
                    Group {
                        if activeKey == .builtin(.code) {
                            CodeEntryRow(entry: entry, isSelected: selectedID == entry.id)
                        } else {
                            TextEntryRow(entry: entry, isSelected: selectedID == entry.id)
                        }
                    }
                    .id(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture { copy(entry) }
                    .onHover { if $0 { selectedID = entry.id } }
                    .contextMenu { entryMenu(entry) }
                }
            }
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: ClipboardEntry) -> some View {
        Button(entry.isPinned ? "取消置顶" : "置顶") { store.togglePinned(id: entry.id) }
        Button("删除", role: .destructive) { delete(entry) }
    }

    private func ensureSelection() {
        guard !entries.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        selectedID = entries.first?.id
    }

    private func copy(_ entry: ClipboardEntry) {
        _ = store.copyToPasteboard(entry, autoPaste: store.settings.autoPaste)
        onDone()
    }

    private func delete(_ entry: ClipboardEntry) {
        store.delete(id: entry.id)
        ensureSelection()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
            if store.copyPinned(number: number, autoPaste: store.settings.autoPaste) {
                onDone()
            }
            return true
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p", let selectedID {
            store.togglePinned(id: selectedID)
            return true
        }
        let columns = activeKey == .builtin(.image) ? ClipboardPanelLayout.imageColumns : 1
        switch event.keyCode {
        case 36, 76:
            guard let entry = entries.first(where: { $0.id == selectedID }) else { return true }
            copy(entry)
            return true
        case 51, 117:
            if let entry = entries.first(where: { $0.id == selectedID }) { delete(entry) }
            return true
        case 53:
            onDone()
            return true
        case 123:
            moveSelection(delta: -1)
            return true
        case 124:
            moveSelection(delta: 1)
            return true
        case 125:
            moveSelection(delta: columns)
            return true
        case 126:
            moveSelection(delta: -columns)
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int) {
        guard !entries.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in entries.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), entries.count - 1)
        selectedID = entries[nextIndex].id
    }
}

// MARK: - Rows

private struct TextEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.previewText.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardPanelLayout.textRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
    }
}

private struct CodeEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    private var lineCount: Int { ClipboardPanelLayout.previewLineCount(entry.text) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(CodeHighlighter.highlight(previewCode))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(ClipboardPanelLayout.codePreviewMaxLines)
                .lineSpacing(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, ClipboardPanelLayout.codeRowPadding / 2)
        .frame(height: ClipboardPanelLayout.codeRowHeight(lineCount: lineCount), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quinary))
        )
    }

    private var previewCode: String {
        let lines = (entry.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        return lines.prefix(ClipboardPanelLayout.codePreviewMaxLines).joined(separator: "\n")
    }
}

private struct ImageEntryCell: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let isSelected: Bool

    private var side: CGFloat { ClipboardPanelLayout.imageCellSide }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(.black.opacity(0.4)))
                    .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
    }
}

// MARK: - Key capture

private struct KeyCaptureView: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CapturingView {
        let view = CapturingView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: CapturingView, context: Context) {
        nsView.onKey = onKey
    }

    final class CapturingView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var didFocus = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFocus else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}
