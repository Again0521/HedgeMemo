import AppKit
import MemeMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct MemePanelView: View {
    @ObservedObject var store: MemeStore
    @State private var query = ""
    @State private var isManaging = false
    @State private var selectedIDs = Set<UUID>()
    @State private var draggedID: UUID?
    @State private var captureService: ClipboardCaptureService?
    @State private var editingMeme: MemeItem?
    @State private var categoryDraft = ""
    @State private var editingCategory: MemeCategory?
    @State private var showsCategorySheet = false
    @State private var showsError = false

    private let columns = [GridItem(.adaptive(minimum: 94, maximum: 132), spacing: 10)]

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
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(store.filteredMemes(query: query)) { meme in
                        MemeTileView(
                            meme: meme,
                            imageURL: store.imageURL(for: meme),
                            isManaging: isManaging,
                            isSelected: selectedIDs.contains(meme.id),
                            categories: store.categories,
                            onSelection: toggleSelection,
                            onCopy: { store.copyToPasteboard(meme) },
                            onEditNote: { editingMeme = meme },
                            onMove: { store.move(ids: [meme.id], to: $0) },
                            onDelete: { store.delete(ids: [meme.id]) },
                            draggedID: $draggedID,
                            onReorder: store.reorder
                        )
                    }
                }
                .padding(2)
            }
            .overlay {
                if store.filteredMemes(query: query).isEmpty {
                    ContentUnavailableView("还没有表情包", systemImage: "photo.on.rectangle.angled")
                }
            }
        }
        .padding(12)
        .frame(width: 430, height: 510)
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
            Image(systemName: "face.smiling")
                .foregroundStyle(.tint)
            TextField("搜索备注或文字", text: $query)
                .textFieldStyle(.roundedBorder)
            Button(action: importImages) {
                Image(systemName: "plus")
            }
            .help("导入图片")
            Menu {
                Button("导入压缩包", action: importArchive)
                Button("导出全部", action: exportArchive)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("导入或导出")
            Button(action: toggleManaging) {
                Image(systemName: isManaging ? "checkmark.circle.fill" : "checklist")
                    .foregroundStyle(isManaging ? Color.accentColor : Color.primary)
            }
            .help(isManaging ? "完成管理" : "批量管理")
            Button(action: { store.captureEnabled.toggle() }) {
                Image(systemName: store.captureEnabled ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(store.captureEnabled ? .red : .primary)
            }
            .help(store.captureEnabled ? "结束捕获" : "开始捕获剪贴板图片")
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
                _ = store.addImage(image)
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

    private func importImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) { _ = store.addImage(image) }
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "MemeMemo-Export.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try MemeArchiveService.export(snapshot: store.snapshot(), repository: store.repository, destination: destination)
        } catch {
            store.report(error)
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let extracted = try MemeArchiveService.extract(from: url)
            defer { MemeArchiveService.removeExtraction(extracted.directory) }
            let sourceImages = extracted.directory.appendingPathComponent("images", isDirectory: true)
            store.importArchive(extracted.manifest, imagesURL: sourceImages)
        } catch {
            store.report(error)
        }
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
                categoryButton("全部", id: nil)
                ForEach(categories) { category in
                    categoryButton(category.name, id: category.id)
                        .contextMenu {
                            Button("重命名") { onRename(category) }
                            Divider()
                            Button("删除分类", role: .destructive) { onDelete(category.id) }
                        }
                }
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("新建分类")
            }
        }
    }

    @ViewBuilder
    private func categoryButton(_ title: String, id: UUID?) -> some View {
        Button(title) { selectedCategoryID = id }
            .buttonStyle(.bordered)
            .tint(selectedCategoryID == id ? .accentColor : nil)
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
