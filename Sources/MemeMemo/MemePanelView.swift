import AppKit
import MemeMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct MemePanelView: View {
    @ObservedObject var store: MemeStore
    @ObservedObject var clipboardStore: ClipboardHistoryStore
    @ObservedObject var screenshotSettingsStore: ScreenshotSettingsStore
    let hotKeyWarnings: [String]
    let onScreenshot: (ScreenshotMode?) -> Void
    @State private var query = ""
    @State private var isManaging = false
    @State private var selectedIDs = Set<UUID>()
    @State private var draggedID: UUID?
    @State private var captureService: ClipboardCaptureService?
    @State private var editingMeme: MemeItem?
    @State private var categoryDraft = ""
    @State private var editingCategory: MemeCategory?
    @State private var showsCategorySheet = false
    @State private var showsSettingsSheet = false
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
        .sheet(isPresented: $showsSettingsSheet) {
            SettingsPanelView(
                clipboardStore: clipboardStore,
                screenshotSettingsStore: screenshotSettingsStore,
                hotKeyWarnings: hotKeyWarnings
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
            Image(nsImage: HedgehogIcon.statusImage)
                .frame(width: 18, height: 18)
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
            Menu {
                Button("按当前模式截图") { onScreenshot(nil) }
                Divider()
                Button("手动框选") { onScreenshot(.manualSelection) }
                Button("智能窗口") { onScreenshot(.smartWindow) }
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .help("截图")
            Button(action: { showsSettingsSheet = true }) {
                Image(systemName: "gearshape")
            }
            .help("设置")
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

private struct SettingsPanelView: View {
    @ObservedObject var clipboardStore: ClipboardHistoryStore
    @ObservedObject var screenshotSettingsStore: ScreenshotSettingsStore
    let hotKeyWarnings: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            GroupBox("剪贴板历史") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: maxEntriesBinding, in: 10...1_000, step: 10) {
                        Text("最多保存 \(clipboardStore.settings.maxEntries) 条")
                    }
                    Toggle("保存图片", isOn: savesImagesBinding)
                    Toggle("复制后自动粘贴", isOn: autoPasteBinding)
                    Picker("条目大小", selection: itemSizeBinding) {
                        ForEach(ClipboardItemSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    HotKeyRecorderRow(title: "剪贴板快捷键", hotKey: clipboardHotKeyBinding)
                    if clipboardStore.settings.autoPaste {
                        PermissionStatusRow(
                            isTrusted: accessibilityTrusted,
                            onRefresh: refreshAccessibilityTrust,
                            onRequest: requestAccessibilityTrust
                        )
                    }
                    Button(role: .destructive) {
                        clipboardStore.clearHistory()
                    } label: {
                        Label("清空剪贴板历史", systemImage: "trash")
                    }
                }
                .padding(.vertical, 4)
            }
            GroupBox("截图") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("默认模式", selection: screenshotModeBinding) {
                        ForEach(ScreenshotMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    HotKeyRecorderRow(title: "截图快捷键", hotKey: screenshotHotKeyBinding)
                    Toggle("记住上次模式", isOn: remembersScreenshotModeBinding)
                    Toggle("截图后打开编辑", isOn: opensEditorAfterCaptureBinding)
                }
                .padding(.vertical, 4)
            }
            if hasHotKeyConflict {
                Label("剪贴板和截图快捷键不能相同", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(hotKeyWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 390)
        .onAppear { refreshAccessibilityTrust() }
    }

    private var maxEntriesBinding: Binding<Int> {
        Binding(
            get: { clipboardStore.settings.maxEntries },
            set: { clipboardStore.settings.maxEntries = $0 }
        )
    }

    private var savesImagesBinding: Binding<Bool> {
        Binding(
            get: { clipboardStore.settings.savesImages },
            set: { clipboardStore.settings.savesImages = $0 }
        )
    }

    private var autoPasteBinding: Binding<Bool> {
        Binding(
            get: { clipboardStore.settings.autoPaste },
            set: { clipboardStore.settings.autoPaste = $0 }
        )
    }

    private var itemSizeBinding: Binding<ClipboardItemSize> {
        Binding(
            get: { clipboardStore.settings.itemSize },
            set: { clipboardStore.settings.itemSize = $0 }
        )
    }

    private var clipboardHotKeyBinding: Binding<HotKeyDefinition> {
        Binding(
            get: { clipboardStore.settings.hotKey ?? .defaultClipboard },
            set: { clipboardStore.settings.hotKey = $0 }
        )
    }

    private var screenshotModeBinding: Binding<ScreenshotMode> {
        Binding(
            get: { screenshotSettingsStore.settings.mode },
            set: { screenshotSettingsStore.settings.mode = $0 }
        )
    }

    private var screenshotHotKeyBinding: Binding<HotKeyDefinition> {
        Binding(
            get: { screenshotSettingsStore.settings.hotKey ?? .defaultScreenshot },
            set: { screenshotSettingsStore.settings.hotKey = $0 }
        )
    }

    private var remembersScreenshotModeBinding: Binding<Bool> {
        Binding(
            get: { screenshotSettingsStore.settings.remembersLastMode },
            set: { screenshotSettingsStore.settings.remembersLastMode = $0 }
        )
    }

    private var opensEditorAfterCaptureBinding: Binding<Bool> {
        Binding(
            get: { screenshotSettingsStore.settings.opensEditorAfterCapture },
            set: { screenshotSettingsStore.settings.opensEditorAfterCapture = $0 }
        )
    }

    private var hasHotKeyConflict: Bool {
        HotKeyPolicy.conflicts(clipboardStore.settings.hotKey ?? .defaultClipboard, screenshotSettingsStore.settings.hotKey ?? .defaultScreenshot)
    }

    private func refreshAccessibilityTrust() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func requestAccessibilityTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }
}

private struct PermissionStatusRow: View {
    let isTrusted: Bool
    let onRefresh: () -> Void
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(isTrusted ? "已允许自动粘贴" : "需要允许辅助功能权限", systemImage: isTrusted ? "checkmark.circle" : "lock")
                .font(.caption)
                .foregroundStyle(isTrusted ? Color.secondary : Color.orange)
            Spacer()
            if isTrusted {
                Button("刷新", action: onRefresh)
                    .font(.caption)
            } else {
                Button("去允许", action: onRequest)
                    .font(.caption)
            }
        }
    }
}

private struct HotKeyRecorderRow: View {
    let title: String
    @Binding var hotKey: HotKeyDefinition
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            HotKeyRecorderButton(hotKey: $hotKey, isRecording: $isRecording)
                .frame(width: 160, height: 28)
        }
    }
}

private struct HotKeyRecorderButton: NSViewRepresentable {
    @Binding var hotKey: HotKeyDefinition
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> HotKeyRecorderNSButton {
        let button = HotKeyRecorderNSButton()
        button.bezelStyle = .rounded
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggleRecording)
        button.onHotKey = { hotKey = $0 }
        return button
    }

    func updateNSView(_ button: HotKeyRecorderNSButton, context: Context) {
        button.title = isRecording ? "按下快捷键..." : HotKeyPolicy.label(hotKey)
        button.isRecording = isRecording
        button.onRecordingChange = { isRecording = $0 }
        button.onHotKey = { hotKey = $0 }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isRecording: $isRecording)
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding var isRecording: Bool

        init(isRecording: Binding<Bool>) {
            _isRecording = isRecording
        }

        @objc func toggleRecording(_ sender: HotKeyRecorderNSButton) {
            isRecording.toggle()
            sender.isRecording = isRecording
            sender.onRecordingChange?(isRecording)
            if isRecording {
                sender.window?.makeFirstResponder(sender)
            }
        }
    }
}

private final class HotKeyRecorderNSButton: NSButton {
    var isRecording = false
    var onHotKey: ((HotKeyDefinition) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        guard let hotKey = HotKeyDefinition(event: event) else { return }
        onHotKey?(hotKey)
        isRecording = false
        onRecordingChange?(false)
        window?.makeFirstResponder(nil)
    }
}

private extension HotKeyDefinition {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)
        guard command || option || control || shift else { return nil }
        let keyCode = UInt32(event.keyCode)
        let key = Self.keyLabel(for: event)
        guard !key.isEmpty else { return nil }
        self.init(
            keyCode: keyCode,
            key: key,
            command: command,
            option: option,
            control: control,
            shift: shift
        )
    }

    static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default:
            return (event.charactersIgnoringModifiers ?? "").uppercased()
        }
    }
}
