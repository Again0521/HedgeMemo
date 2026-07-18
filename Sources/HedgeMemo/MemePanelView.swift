import AppKit
import HedgeMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct MemePanelView: View {
    @ObservedObject var store: MemeStore
    var onDismiss: () -> Void = {}
    @State private var query = ""
    @State private var isManaging = false
    @State private var selectedIDs = Set<UUID>()
    @State private var selectionAnchorID: UUID?
    @State private var draggedID: UUID?
    /// Pointer position in `MemeGridSpace` while a reorder drag is active.
    @State private var dragLocation: CGPoint = .zero
    /// A prospective insertion is visual state only. Persisting a new order
    /// while the pointer is still moving makes a slow drag repeatedly rebuild
    /// the grid, which is the source of the visible tile jitter.
    @State private var dropTargetID: UUID?
    @State private var dropsAtEnd = false
    /// The grid's top edge in the scroll viewport's space; negative once the
    /// grid is scrolled. Lets the drag handler know when the pointer reaches
    /// the viewport edges so it can autoscroll.
    @State private var gridMinYInViewport: CGFloat = 0
    @State private var lastAutoscroll = Date.distantPast
    @State private var captureService: ClipboardCaptureService?
    @State private var editingMeme: MemeItem?
    @State private var showsError = false

    // Three visible rows of square tiles; the grid scrolls beyond that.
    private let tileSide: CGFloat = 92
    private let tileSpacing: CGFloat = 8
    // The panel width is fixed, so the column count is too. Reorder targets
    // are computed from these fixed slots — never from tile frames, which
    // move during the make-room animation.
    private let columnCount = 4
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSide), spacing: tileSpacing), count: columnCount)
    }
    private var visibleMemes: [MemeItem] { store.filteredMemes(query: query) }
    private var gridHeight: CGFloat { tileSide * 3 + tileSpacing * 2 + 4 }

    var body: some View {
        VStack(spacing: 10) {
            header
            CategoryBarView(
                categories: store.categories,
                selectedCategoryID: $store.selectedCategoryID,
                onAdd: beginNewCategory,
                onRename: beginRenameCategory,
                onDelete: store.deleteCategory
            )
            if isManaging {
                managementBar
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: tileSpacing) {
                        ForEach(visibleMemes) { meme in
                            MemeTileView(
                                meme: meme,
                                imageURL: store.imageURL(for: meme),
                                side: tileSide,
                                isManaging: isManaging,
                                isSelected: selectedIDs.contains(meme.id),
                                isDragged: draggedID == meme.id,
                                categories: store.categories,
                                onSelection: select,
                                onCopy: {
                                    store.copyToPasteboard(meme)
                                    onDismiss()
                                },
                                onEditNote: { editingMeme = meme },
                                onMove: { store.move(ids: [meme.id], to: $0) },
                                onDelete: { store.delete(ids: [meme.id]) },
                                onDragChanged: { id, location in
                                    handleDragChanged(id: id, location: location, proxy: proxy)
                                },
                                onDragEnded: endDrag
                            )
                            .id(meme.id)
                        }
                        MemeImportTile(
                            side: tileSide,
                            onImport: importImages
                        )
                    }
                    .overlay(alignment: .topLeading) { floatingDragTile }
                    .coordinateSpace(name: MemeGridSpace.name)
                    .background(
                        // Tracks how far the grid is scrolled so the drag
                        // handler can autoscroll at the viewport edges.
                        GeometryReader { geometry in
                            let minY = geometry.frame(in: .named(Self.viewportSpace)).minY
                            Color.clear
                                .onAppear { gridMinYInViewport = minY }
                                .onChange(of: minY) { _, y in gridMinYInViewport = y }
                        }
                    )
                    .padding(2)
                }
                .coordinateSpace(name: Self.viewportSpace)
            }
            .frame(height: gridHeight)
            .overlay {
                if visibleMemes.isEmpty {
                    ContentUnavailableView("还没有表情包", systemImage: "photo.on.rectangle.angled")
                        // The import tile remains actionable even in a new,
                        // empty category; this placeholder is informational.
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(12)
        .frame(width: 420)
        // NSPopover already owns one native material. Stacking a second visual
        // effect view here creates a separate compositing pass and is why the
        // menu-bar panel previously looked unlike the clipboard surface.
        .sheet(item: $editingMeme) { meme in
            NoteEditorSheet(meme: meme) { store.updateNote(id: meme.id, note: $0) }
        }
        .alert("操作失败", isPresented: $showsError) {
            Button("好") { store.clearError() }
        } message: {
            Text(store.lastError ?? "未知错误")
        }
        .onChange(of: store.captureEnabled) { _, enabled in
            configureCapture(enabled: enabled)
        }
        .onChange(of: store.lastError) { _, error in
            showsError = error != nil
        }
        .background(
            MemeManagementKeyCapture(
                isEnabled: isManaging,
                selectAll: {
                    selectedIDs = Set(visibleMemes.map(\.id))
                    selectionAnchorID = visibleMemes.first?.id
                }
            )
            .frame(width: 1, height: 1)
        )
        .onDisappear {
            captureService?.stop()
            clearDragState()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PanelSearchField(placeholder: "搜索备注或文字", text: $query)
            HoverIconButton(
                systemImage: isManaging ? "checkmark.circle.fill" : "checklist",
                tint: isManaging ? .accentColor : .primary,
                help: isManaging ? "完成管理" : "批量管理",
                action: toggleManaging
            )
            HoverIconButton(
                systemImage: store.captureEnabled ? "record.circle.fill" : "record.circle",
                tint: store.captureEnabled ? .red : .primary,
                help: store.captureEnabled ? "结束捕获" : "开始捕获剪贴板图片",
                action: { store.captureEnabled.toggle() }
            )
        }
    }

    private var managementBar: some View {
        HStack {
            Text("已选 \(selectedIDs.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("未分类") { store.move(ids: selectedIDs, to: nil) }
                ForEach(store.categories) { category in
                    Button(category.name) { store.move(ids: selectedIDs, to: category.id) }
                }
            } label: {
                Label("移动", systemImage: "folder")
            }
            .disabled(selectedIDs.isEmpty)
            Spacer()
            Button(role: .destructive) {
                store.delete(ids: selectedIDs)
                selectedIDs.removeAll()
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selectedIDs.isEmpty)
        }
        .font(.caption)
    }

    private func toggleManaging() {
        isManaging.toggle()
        if !isManaging {
            selectedIDs.removeAll()
            selectionAnchorID = nil
        }
    }

    /// Management is a batch workflow, so each ordinary click toggles its tile
    /// instead of silently replacing the previous selection. Command remains
    /// equivalent to the familiar Finder toggle and Shift still selects a
    /// visible contiguous range.
    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || !flags.contains(.shift) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
            selectionAnchorID = id
            return
        }
        if flags.contains(.shift),
           let anchor = selectionAnchorID,
           let first = visibleMemes.firstIndex(where: { $0.id == anchor }),
           let last = visibleMemes.firstIndex(where: { $0.id == id }) {
            selectedIDs = Set(visibleMemes[min(first, last)...max(first, last)].map(\.id))
            return
        }
    }

    private func configureCapture(enabled: Bool) {
        if enabled {
            let service = ClipboardCaptureService { image in
                _ = store.addImageData(image)
            }
            captureService = service
            service.start()
        } else {
            captureService?.stop()
            captureService = nil
        }
    }

    private func beginNewCategory() {
        presentCategoryEditor(title: "新建分类", initialName: "") { name in
            store.addCategory(name: name)
        }
    }

    private func beginRenameCategory(_ category: MemeCategory) {
        presentCategoryEditor(title: "重命名分类", initialName: category.name) { name in
            store.renameCategory(id: category.id, name: name)
        }
    }

    /// NSPopover sheets stay in the popover's responder chain. Pressing Return
    /// there can close the popover before SwiftUI confirms the edit, leaving a
    /// hidden sheet as the key responder. A small app-modal `NSAlert` is the
    /// narrow AppKit bridge here: it is frontmost, owns Return itself, and
    /// returns one value back to the SwiftUI store only after confirmation.
    @MainActor
    private func presentCategoryEditor(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "输入分类名称后按 Return 保存。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: initialName)
        field.placeholderString = "分类名称"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        // `NSAlert` otherwise initially focuses its default button. Explicitly
        // nominate the field so typing and Return stay entirely inside this
        // frontmost modal session from the first event.
        alert.window.initialFirstResponder = field

        // Make the native modal dialog the active event target before it runs.
        // This keeps Return inside the dialog instead of sending it to the
        // status-item popover's close handler.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        onSave(field.stringValue)
    }

    // MARK: - Gesture-driven reordering

    private static let viewportSpace = "memeGridViewport"
    /// The floating copy that follows the pointer during a reorder drag. It
    /// lives in the grid's own coordinate space (`dragLocation` is captured
    /// there), so it stays aligned with the pointer regardless of scrolling.
    @ViewBuilder
    private var floatingDragTile: some View {
        if let draggedID, let meme = visibleMemes.first(where: { $0.id == draggedID }) {
            MemeTileContent(meme: meme, imageURL: store.imageURL(for: meme), side: tileSide)
                .scaleEffect(1.05)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .position(dragLocation)
                .allowsHitTesting(false)
        }
    }

    /// Maps a pointer position in grid space onto a fixed slot index. Slots
    /// never move (unlike tiles, which animate aside), so a stationary pointer
    /// always resolves to the same slot and the grid cannot oscillate.
    private func slotIndex(at location: CGPoint) -> Int {
        let cell = tileSide + tileSpacing
        let column = min(columnCount - 1, max(0, Int(location.x / cell)))
        let row = max(0, Int(location.y / cell))
        return row * columnCount + column
    }

    private func handleDragChanged(id: UUID, location: CGPoint, proxy: ScrollViewProxy) {
        if draggedID != id { draggedID = id }
        dragLocation = location
        let memes = visibleMemes
        let slot = slotIndex(at: location)
        if slot >= memes.count {
            // The import tile's slot and anything past it mean "the end".
            // This is intentionally not persisted until mouse-up.
            dropsAtEnd = true
            dropTargetID = nil
        } else {
            dropsAtEnd = false
            dropTargetID = memes[slot].id
        }
        autoscrollIfNeeded(location: location, proxy: proxy)
    }

    private func endDrag() {
        defer { clearDragState() }
        guard let draggedID else { return }
        if dropsAtEnd {
            store.reorderToEnd(draggedID: draggedID, categoryID: store.selectedCategoryID)
        } else if let targetID = dropTargetID, targetID != draggedID {
            store.reorder(draggedID: draggedID, over: targetID)
        }
    }

    private func clearDragState() {
        draggedID = nil
        dropTargetID = nil
        dropsAtEnd = false
    }

    /// `DragGesture` does not scroll the enclosing ScrollView by itself, so
    /// nudge it row by row while the pointer dwells near a viewport edge.
    private func autoscrollIfNeeded(location: CGPoint, proxy: ScrollViewProxy) {
        guard Date.now.timeIntervalSince(lastAutoscroll) > 0.25 else { return }
        let memes = visibleMemes
        guard !memes.isEmpty else { return }
        let edge: CGFloat = 30
        let cell = tileSide + tileSpacing
        let viewportY = location.y + gridMinYInViewport
        let row = max(0, Int(location.y / cell))
        if viewportY < edge {
            let index = (row - 1) * columnCount
            guard memes.indices.contains(index) else { return }
            lastAutoscroll = .now
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(memes[index].id, anchor: .top)
            }
        } else if viewportY > gridHeight - edge {
            let index = min(memes.count - 1, (row + 1) * columnCount + columnCount - 1)
            guard index > row * columnCount else { return }
            lastAutoscroll = .now
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(memes[index].id, anchor: .bottom)
            }
        }
    }

    /// The trailing grid slot is an import affordance first.  It doubles as
    /// the end insertion target only while a reorder drag is active, which
    /// preserves a stable grid and makes dropping at the row tail predictable.
    private func importImages() {
        let panel = NSOpenPanel()
        panel.title = "导入表情包"
        panel.prompt = "导入"
        panel.message = "可选择图片文件或文件夹；文件夹中的图片会批量导入当前分类。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }

        let targetCategoryID = store.selectedCategoryID
        let payloads = MemeImageImport.collectPayloads(from: panel.urls)
        guard !payloads.isEmpty else { return }
        for payload in payloads {
            _ = store.addImageData(payload, categoryID: targetCategoryID)
        }
    }
}

private struct MemeImportTile: View {
    let side: CGFloat
    let onImport: () -> Void

    var body: some View {
        Button(action: onImport) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .regular))
                // This remains a neutral import affordance even while a meme
                // is being dragged across its end slot. Reordering has no
                // visible "move to end" emphasis in the regular UI.
                .foregroundStyle(Color.secondary)
                .frame(width: side, height: side)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .help("从文件或文件夹批量导入到当前分类")
        .accessibilityLabel("导入表情包")
    }
}

private enum MemeImageImport {
    static func collectPayloads(from selectedURLs: [URL]) -> [ImageAssetData] {
        let urls = selectedURLs.flatMap(imageFiles(in:))
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard seen.insert(url.standardizedFileURL).inserted else { return nil }
            return ImageAssetData(fileURL: url)
        }
    }

    private static func imageFiles(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isImageFile(url) ? [url] : [] }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: options)
        return (enumerator?.allObjects as? [URL] ?? []).filter(isImageFile)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values?.isRegularFile == true else { return false }
        return values?.contentType?.conforms(to: .image) == true
    }
}

private struct CategoryBarView: View {
    let categories: [MemeCategory]
    @Binding var selectedCategoryID: UUID?
    let onAdd: () -> Void
    let onRename: (MemeCategory) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(title: "全部", isSelected: selectedCategoryID == nil) {
                    selectedCategoryID = nil
                }
                ForEach(categories) { category in
                    CategoryChip(title: category.name, isSelected: selectedCategoryID == category.id) {
                        selectedCategoryID = category.id
                    }
                    .contextMenu {
                        Button("重命名") { onRename(category) }
                        Divider()
                        Button("删除分类", role: .destructive) { onDelete(category.id) }
                    }
                }
                HoverIconButton(systemImage: "plus", help: "新建分类", action: onAdd)
            }
        }
    }
}

/// A popover does not make SwiftUI's invisible key views first responder while
/// a text field is active. Keep the monitor scoped to this popover window so
/// Command-A works in management mode without stealing normal text editing.
private struct MemeManagementKeyCapture: NSViewRepresentable {
    let isEnabled: Bool
    let selectAll: () -> Void

    func makeNSView(context: Context) -> MemeManagementCapturingView {
        let view = MemeManagementCapturingView()
        view.isEnabled = isEnabled
        view.selectAll = selectAll
        return view
    }

    func updateNSView(_ nsView: MemeManagementCapturingView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.selectAll = selectAll
    }

    final class MemeManagementCapturingView: NSView {
        var isEnabled = false
        var selectAll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      event.window === self.window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                      event.charactersIgnoringModifiers?.lowercased() == "a" else {
                    return event
                }
                self.selectAll?()
                return nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private struct NoteEditorSheet: View {
    let meme: MemeItem
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(meme: MemeItem, onSave: @escaping (String) -> Void) {
        self.meme = meme
        self.onSave = onSave
        _note = State(initialValue: meme.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改备注").font(.headline)
            TextField("备注", text: $note, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
