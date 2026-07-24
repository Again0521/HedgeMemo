import AppKit
import HedgeMemoCore
import SwiftUI

/// A single, explicit selection model is shared by ZIP import and export.  It
/// keeps the two flows honest: a selected category means exactly the same
/// thing in both directions.
struct ArchiveCategorySelection {
    var includeUncategorizedMemes = false
    var memeCategoryIDs: Set<UUID> = []
    var clipboardCategoryKeys: Set<String> = []

    var includesMemes: Bool { includeUncategorizedMemes || !memeCategoryIDs.isEmpty }
    var includesClipboard: Bool { !clipboardCategoryKeys.isEmpty }
    var includesAnything: Bool { includesMemes || includesClipboard }
}

typealias ArchiveExportSelection = ArchiveCategorySelection
typealias ArchiveImportSelection = ArchiveCategorySelection

/// AppKit owns only the modal-window lifecycle. SwiftUI still owns the
/// checkbox state and passes one final value back through a small closure.
/// In particular, the traffic-light close button must stop the modal loop;
/// without this delegate path the status-bar menu remains in a tracking state
/// after a user closes export/import with the red button.
@MainActor
private final class ArchiveSelectionSession: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private var finished = false

    init(title: String, size: NSSize) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: panel)
    }

    func finish(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }
        finished = true
        panel.orderOut(nil)
        NSApp.stopModal(withCode: response)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }
}

@MainActor
enum ArchiveExportSelectionPanel {
    static func run(memeStore: MemeStore, clipboardStore: ClipboardHistoryStore) -> ArchiveExportSelection? {
        let categories = memeStore.categories
        let clipboardKeys = clipboardStore.settings.orderedCategoryKeys
        let session = ArchiveSelectionSession(
            title: L10n.text("选择导出内容"),
            size: ArchiveSelectionMetrics.size(rowCount: categories.count + clipboardKeys.count + 1)
        )
        var result: ArchiveExportSelection?
        let root = ArchiveSelectionView(
            title: L10n.text("选择导出内容"),
            subtitle: L10n.text("按分类打包成一个 HedgeMemo ZIP 文件。"),
            confirmationTitle: L10n.text("导出 ZIP"),
            memeCategories: categories,
            clipboardKeys: clipboardKeys,
            customCategories: clipboardStore.settings.customCategories ?? [],
            initialSelection: ArchiveExportSelection(
                includeUncategorizedMemes: true,
                memeCategoryIDs: Set(categories.map(\.id)),
                clipboardCategoryKeys: Set(clipboardKeys.map(\.storageValue))
            ),
            onCancel: { session.finish(.cancel) },
            onConfirm: { selection in
                result = selection
                session.finish(.OK)
            }
        )
        PanelMaterialHost.install(root, in: session.panel, cornerRadius: 14)
        session.present()
        return result
    }
}

@MainActor
enum ArchiveImportSelectionPanel {
    static func run(manifest: MemeArchiveManifest) -> ArchiveImportSelection? {
        let memeSnapshot = manifest.memeSnapshot
        let clipboardSnapshot = manifest.clipboardSnapshot
        let memeCategories = memeSnapshot?.categories ?? []
        let uncategorizedMemes = memeSnapshot?.memes.contains(where: { $0.categoryID == nil }) == true
        let clipboardKeys = archiveClipboardKeys(in: clipboardSnapshot)
        let customs = clipboardSnapshot?.settings.customCategories ?? []
        let session = ArchiveSelectionSession(
            title: L10n.text("选择导入内容"),
            size: ArchiveSelectionMetrics.size(
                rowCount: memeCategories.count + clipboardKeys.count + (uncategorizedMemes ? 1 : 0)
            )
        )
        var result: ArchiveImportSelection?
        let root = ArchiveSelectionView(
            title: L10n.text("选择导入内容"),
            subtitle: L10n.text("已识别压缩包内的分类；只会导入勾选的内容。"),
            confirmationTitle: L10n.text("导入所选内容"),
            memeCategories: memeCategories,
            clipboardKeys: clipboardKeys,
            customCategories: customs,
            initialSelection: ArchiveImportSelection(
                includeUncategorizedMemes: uncategorizedMemes,
                memeCategoryIDs: Set(memeCategories.map(\.id)),
                clipboardCategoryKeys: Set(clipboardKeys.map(\.storageValue))
            ),
            onCancel: { session.finish(.cancel) },
            onConfirm: { selection in
                result = selection
                session.finish(.OK)
            }
        )
        PanelMaterialHost.install(root, in: session.panel, cornerRadius: 14)
        session.present()
        return result
    }

    private static func archiveClipboardKeys(in snapshot: ClipboardHistorySnapshot?) -> [ClipboardCategoryKey] {
        guard let snapshot else { return [] }
        var keys = ClipboardContentCategory.allCases
            .filter { category in snapshot.entries.contains { $0.contentCategory == category } }
            .map(ClipboardCategoryKey.builtin)
        let customs = snapshot.settings.customCategories ?? []
        keys += customs.compactMap { custom in
            let key = ClipboardCategoryKey.custom(custom.id)
            return snapshot.entries.contains { $0.matches(key: key, customCategories: customs) } ? key : nil
        }
        return keys
    }
}

private enum ArchiveSelectionMetrics {
    static func size(rowCount: Int) -> NSSize {
        // Size the window from the rows it actually presents.  The header and
        // footer need about 180 points together (the header clears the title-bar
        // controls); every category adds one native control row.  This keeps a
        // small import/export sheet compact while a long list still scrolls
        // rather than growing beyond the screen.
        let visibleRows = max(1, rowCount)
        let height = min(540, max(292, 180 + CGFloat(visibleRows) * 30))
        return NSSize(width: 468, height: height)
    }
}

private struct ArchiveSelectionView: View {
    let title: String
    let subtitle: String
    let confirmationTitle: String
    let memeCategories: [MemeCategory]
    let clipboardKeys: [ClipboardCategoryKey]
    let customCategories: [CustomClipboardCategory]
    let onCancel: () -> Void
    let onConfirm: (ArchiveCategorySelection) -> Void

    @State private var includeUncategorizedMemes: Bool
    @State private var memeCategoryIDs: Set<UUID>
    @State private var clipboardCategoryKeys: Set<String>
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true

    init(
        title: String,
        subtitle: String,
        confirmationTitle: String,
        memeCategories: [MemeCategory],
        clipboardKeys: [ClipboardCategoryKey],
        customCategories: [CustomClipboardCategory],
        initialSelection: ArchiveCategorySelection,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ArchiveCategorySelection) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.confirmationTitle = confirmationTitle
        self.memeCategories = memeCategories
        self.clipboardKeys = clipboardKeys
        self.customCategories = customCategories
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _includeUncategorizedMemes = State(initialValue: initialSelection.includeUncategorizedMemes)
        _memeCategoryIDs = State(initialValue: initialSelection.memeCategoryIDs)
        _clipboardCategoryKeys = State(initialValue: initialSelection.clipboardCategoryKeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            // The window uses a full-size content view under a transparent title
            // bar, so the header must clear the traffic-light controls rather
            // than crowd up against the very top edge.
            .padding(.top, 34)
            .padding(.bottom, 14)

            if memeCategories.isEmpty && clipboardKeys.isEmpty && !includeUncategorizedMemes {
                ContentUnavailableView(L10n.text("压缩包中没有可导入的分类"), systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !memeCategories.isEmpty || includeUncategorizedMemes {
                            selectionSection(title: L10n.text("表情包"), systemImage: "face.smiling") {
                                if includeUncategorizedMemes {
                                    Toggle(L10n.text("未分类"), isOn: $includeUncategorizedMemes)
                                }
                                ForEach(memeCategories) { category in
                                    Toggle(category.name, isOn: binding(for: category.id, in: $memeCategoryIDs))
                                }
                            }
                        }
                        if !clipboardKeys.isEmpty {
                            selectionSection(title: L10n.text("剪贴板"), systemImage: "clipboard") {
                                ForEach(clipboardKeys, id: \.storageValue) { key in
                                    Toggle(clipboardTitle(for: key), isOn: binding(for: key.storageValue, in: $clipboardCategoryKeys))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
            }

            Divider()
            HStack(spacing: 10) {
                Text(L10n.text(selection.includesAnything ? "可随时从设置或菜单栏继续操作" : "至少选择一个分类"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(L10n.text("取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmationTitle) { onConfirm(selection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!selection.includesAnything)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 468)
    }

    private var selection: ArchiveCategorySelection {
        ArchiveCategorySelection(
            includeUncategorizedMemes: includeUncategorizedMemes,
            memeCategoryIDs: memeCategoryIDs,
            clipboardCategoryKeys: clipboardCategoryKeys
        )
    }

    @ViewBuilder
    private func selectionSection<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(.leading, 2)
        }
    }

    private func clipboardTitle(for key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): category.displayName
        case .custom(let id): customCategories.first(where: { $0.id == id })?.name ?? L10n.text("自定义分类")
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
