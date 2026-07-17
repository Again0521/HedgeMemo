import AppKit
import MemeMemoCore
import SwiftUI

struct ArchiveExportSelection {
    var includeUncategorizedMemes = true
    var memeCategoryIDs: Set<UUID> = []
    var clipboardCategoryKeys: Set<String> = []

    var exportsMemes: Bool { includeUncategorizedMemes || !memeCategoryIDs.isEmpty }
    var exportsClipboard: Bool { !clipboardCategoryKeys.isEmpty }
}

@MainActor
enum ArchiveExportSelectionPanel {
    static func run(memeStore: MemeStore, clipboardStore: ClipboardHistoryStore) -> ArchiveExportSelection? {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "选择导出内容"
        panel.isReleasedWhenClosed = false
        panel.center()

        var result: ArchiveExportSelection?
        let root = ArchiveExportSelectionView(
            memeCategories: memeStore.categories,
            clipboardKeys: clipboardStore.settings.orderedCategoryKeys,
            customCategories: clipboardStore.settings.customCategories ?? [],
            onCancel: {
                panel.orderOut(nil)
                NSApp.stopModal(withCode: .cancel)
            },
            onExport: { selection in
                result = selection
                panel.orderOut(nil)
                NSApp.stopModal(withCode: .OK)
            }
        )
        panel.contentView = NSHostingView(rootView: root)
        NSApp.runModal(for: panel)
        return result
    }
}

private struct ArchiveExportSelectionView: View {
    let memeCategories: [MemeCategory]
    let clipboardKeys: [ClipboardCategoryKey]
    let customCategories: [CustomClipboardCategory]
    let onCancel: () -> Void
    let onExport: (ArchiveExportSelection) -> Void

    @State private var includeUncategorizedMemes = true
    @State private var memeCategoryIDs: Set<UUID> = []
    @State private var clipboardCategoryKeys: Set<String> = []

    init(
        memeCategories: [MemeCategory],
        clipboardKeys: [ClipboardCategoryKey],
        customCategories: [CustomClipboardCategory],
        onCancel: @escaping () -> Void,
        onExport: @escaping (ArchiveExportSelection) -> Void
    ) {
        self.memeCategories = memeCategories
        self.clipboardKeys = clipboardKeys
        self.customCategories = customCategories
        self.onCancel = onCancel
        self.onExport = onExport
        _memeCategoryIDs = State(initialValue: Set(memeCategories.map(\.id)))
        _clipboardCategoryKeys = State(initialValue: Set(clipboardKeys.map(\.storageValue)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择要写入 MemeMemo ZIP 的内容")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Text("可按分类导出；不会导出任何应用外部文件或访问路径。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectionSection(title: "表情包", systemImage: "face.smiling") {
                        Toggle("未分类", isOn: $includeUncategorizedMemes)
                        ForEach(memeCategories) { category in
                            Toggle(category.name, isOn: binding(for: category.id, in: $memeCategoryIDs))
                        }
                    }
                    selectionSection(title: "剪贴板", systemImage: "clipboard") {
                        ForEach(clipboardKeys, id: \.storageValue) { key in
                            Toggle(clipboardTitle(for: key), isOn: binding(for: key.storageValue, in: $clipboardCategoryKeys))
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text(selection.exportsMemes || selection.exportsClipboard ? "将创建 .zip 文件" : "至少选择一个分类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                Button("继续导出") { onExport(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!selection.exportsMemes && !selection.exportsClipboard)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }

    private var selection: ArchiveExportSelection {
        ArchiveExportSelection(
            includeUncategorizedMemes: includeUncategorizedMemes,
            memeCategoryIDs: memeCategoryIDs,
            clipboardCategoryKeys: clipboardCategoryKeys
        )
    }

    @ViewBuilder
    private func selectionSection<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func clipboardTitle(for key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): category.displayName
        case .custom(let id): customCategories.first(where: { $0.id == id })?.name ?? "自定义分类"
        }
    }

    private func binding<T: Hashable>(for value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { enabled in
                if enabled { set.wrappedValue.insert(value) }
                else { set.wrappedValue.remove(value) }
            }
        )
    }
}
