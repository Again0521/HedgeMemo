import AppKit
import MemeMemoCore
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController: NSObject {
    private let store: ClipboardHistoryStore
    private var panel: NSPanel?

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    func toggle() {
        if panel?.isVisible == true { hide() }
        else { show() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(store: store) { [weak self] in
            self?.hide()
        })
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.applyTranslucentChrome(cornerRadius: 14)
        return panel
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
}

struct ClipboardHistoryPanelView: View {
    @ObservedObject var store: ClipboardHistoryStore
    let onDone: () -> Void

    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var category: ClipboardContentCategory = .all

    private var entries: [ClipboardEntry] { store.orderedEntries(query: query, category: category) }

    var body: some View {
        VStack(spacing: 10) {
            header
            categoryBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(entries) { entry in
                            ClipboardEntryRow(
                                entry: entry,
                                imageURL: store.imageURL(for: entry),
                                isSelected: selectedID == entry.id,
                                itemSize: store.settings.itemSize
                            )
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { copy(entry) }
                            .contextMenu {
                                Button(entry.isPinned ? "取消置顶" : "置顶") { store.togglePinned(id: entry.id) }
                                Button("删除", role: .destructive) { delete(entry) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("没有剪贴板记录", systemImage: "doc.on.clipboard")
                }
            }
        }
        .padding(12)
        .frame(width: 430, height: 520)
        .background(VisualEffectBackground())
        .background(KeyCaptureView { event in handleKey(event) }.frame(width: 0, height: 0))
        .onAppear { ensureSelection() }
        .onChange(of: query) { _, _ in ensureSelection() }
        .onChange(of: category) { _, _ in ensureSelection() }
        .onChange(of: store.entries) { _, _ in ensureSelection() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板", text: $query)
                .textFieldStyle(.roundedBorder)
            Button(action: onDone) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
    }

    private var categoryBar: some View {
        Picker("类型", selection: $category) {
            ForEach(ClipboardContentCategory.allCases, id: \.self) { item in
                Label(item.displayName, systemImage: item.systemImage).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
        switch event.keyCode {
        case 36, 76:
            guard let entry = entries.first(where: { $0.id == selectedID }) else { return true }
            copy(entry)
            return true
        case 51, 117:
            if let entry = entries.first(where: { $0.id == selectedID }) { delete(entry) }
            return true
        case 125:
            moveSelection(delta: 1)
            return true
        case 126:
            moveSelection(delta: -1)
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

private struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let isSelected: Bool
    let itemSize: ClipboardItemSize

    private var rowHeight: CGFloat {
        switch itemSize {
        case .compact: 56
        case .regular: 64
        case .large: 78
        }
    }

    private var title: String {
        switch entry.contentCategory {
        case .image: "图片"
        case .code: "代码"
        case .text, .all: entry.previewText
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.createdAt, style: .relative)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var thumbnail: some View {
        let side = rowHeight - 20
        if entry.kind == .image, let imageURL, let image = NSImage(contentsOf: imageURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: entry.contentCategory.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: side, height: side)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

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
