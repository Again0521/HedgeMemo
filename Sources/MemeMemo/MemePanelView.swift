import AppKit
import MemeMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct MemePanelView: View {
    @ObservedObject var store: MemeStore
    var onDismiss: () -> Void = {}
    @State private var query = ""
    @State private var isManaging = false
    @State private var selectedIDs = Set<UUID>()
    @State private var draggedID: UUID?
    @State private var insertionProposal: MemeInsertionProposal?
    @State private var captureService: ClipboardCaptureService?
    @State private var editingMeme: MemeItem?
    @State private var categoryDraft = ""
    @State private var editingCategory: MemeCategory?
    @State private var showsCategorySheet = false
    @State private var showsError = false

    // Three visible rows of square tiles; the grid scrolls beyond that.
    private let tileSide: CGFloat = 92
    private let tileSpacing: CGFloat = 8
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSide, maximum: tileSide + 12), spacing: tileSpacing)]
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: tileSpacing) {
                    ForEach(visibleMemes) { meme in
                        MemeTileView(
                            meme: meme,
                            imageURL: store.imageURL(for: meme),
                            side: tileSide,
                            isManaging: isManaging,
                            isSelected: selectedIDs.contains(meme.id),
                            categories: store.categories,
                            onSelection: toggleSelection,
                            onCopy: {
                                store.copyToPasteboard(meme)
                                onDismiss()
                            },
                            onEditNote: { editingMeme = meme },
                            onMove: { store.move(ids: [meme.id], to: $0) },
                            onDelete: { store.delete(ids: [meme.id]) },
                            draggedID: $draggedID,
                            insertionProposal: $insertionProposal,
                            onReorder: { draggedID, targetID, insertAfter in
                                store.reorder(draggedID: draggedID, relativeTo: targetID, insertAfter: insertAfter)
                            }
                        )
                    }
                    MemeImportTile(
                        side: tileSide,
                        isReordering: draggedID != nil,
                        draggedID: $draggedID,
                        onImport: importImages,
                        onDropAtEnd: moveDraggedMemeToEnd
                    )
                }
                .padding(2)
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
        .sheet(isPresented: $showsCategorySheet) {
            CategoryEditorSheet(
                title: editingCategory == nil ? "新建分类" : "重命名分类",
                name: $categoryDraft,
                onSave: saveCategory
            )
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
        .onDisappear { captureService?.stop() }
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
        if !isManaging { selectedIDs.removeAll() }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
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
        editingCategory = nil
        categoryDraft = ""
        showsCategorySheet = true
    }

    private func beginRenameCategory(_ category: MemeCategory) {
        editingCategory = category
        categoryDraft = category.name
        showsCategorySheet = true
    }

    private func saveCategory() {
        if let category = editingCategory { store.renameCategory(id: category.id, name: categoryDraft) }
        else { store.addCategory(name: categoryDraft) }
        showsCategorySheet = false
    }

    private func moveDraggedMemeToEnd(_ id: UUID) {
        let categoryID = store.memes.first(where: { $0.id == id })?.categoryID
        store.reorderToEnd(draggedID: id, categoryID: categoryID)
        insertionProposal = nil
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
    let isReordering: Bool
    @Binding var draggedID: UUID?
    let onImport: () -> Void
    let onDropAtEnd: (UUID) -> Void

    var body: some View {
        Button(action: onImport) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(isReordering ? Color.accentColor : Color.secondary)
                .frame(width: side, height: side)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isReordering ? Color.accentColor : Color.primary.opacity(0.12),
                            style: StrokeStyle(lineWidth: isReordering ? 2 : 1, dash: isReordering ? [5, 4] : [])
                        )
                }
        }
        .buttonStyle(.plain)
        .onDrop(
            of: [UTType.plainText],
            delegate: MemeEndDropDelegate(draggedID: $draggedID, onDropAtEnd: onDropAtEnd)
        )
        .help(isReordering ? "拖放到这里移至末尾" : "从文件或文件夹批量导入到当前分类")
        .accessibilityLabel(isReordering ? "将表情包移到末尾" : "导入表情包")
    }
}

private struct MemeEndDropDelegate: DropDelegate {
    @Binding var draggedID: UUID?
    let onDropAtEnd: (UUID) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID else { return false }
        onDropAtEnd(draggedID)
        self.draggedID = nil
        return true
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

private struct CategoryEditorSheet: View {
    let title: String
    @Binding var name: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("分类名称", text: $name)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 280)
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
