import AppKit
import HedgeMemoCore
import SwiftUI

/// A reusable modal category picker shared by Settings and the status-item
/// context menu. The modal session is intentionally AppKit-owned because both
/// callers live outside a single SwiftUI scene hierarchy.
@MainActor
enum ClipboardClearSelectionPanel {
    static func run(store: ClipboardHistoryStore) {
        let keys = store.settings.orderedCategoryKeys
        guard !keys.isEmpty else { return }

        let session = ClipboardClearSelectionSession(
            size: ClipboardClearSelectionMetrics.size(rowCount: keys.count)
        )
        let root = ClipboardClearSelectionView(
            store: store,
            keys: keys,
            initialSelection: Set(keys),
            onCancel: { session.finish() },
            onConfirm: { selection in
                store.clearHistory(matching: selection)
                session.finish()
            }
        )
        PanelMaterialHost.install(root, in: session.panel, cornerRadius: 14)
        session.present()
    }
}

@MainActor
private final class ClipboardClearSelectionSession: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private var finished = false

    init(size: NSSize) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = L10n.text("清除剪贴板")
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

    func finish() {
        guard !finished else { return }
        finished = true
        panel.orderOut(nil)
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

private enum ClipboardClearSelectionMetrics {
    static func size(rowCount: Int) -> NSSize {
        let height = min(540, max(292, 190 + CGFloat(max(1, rowCount)) * 30))
        return NSSize(width: 440, height: height)
    }
}

private struct ClipboardClearSelectionView: View {
    @ObservedObject var store: ClipboardHistoryStore
    let keys: [ClipboardCategoryKey]
    let onCancel: () -> Void
    let onConfirm: (Set<ClipboardCategoryKey>) -> Void

    @State private var selectedKeys: Set<ClipboardCategoryKey>
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true

    init(
        store: ClipboardHistoryStore,
        keys: [ClipboardCategoryKey],
        initialSelection: Set<ClipboardCategoryKey>,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Set<ClipboardCategoryKey>) -> Void
    ) {
        self.store = store
        self.keys = keys
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedKeys = State(initialValue: initialSelection)
    }

    private var removalCount: Int { store.entryCount(matching: selectedKeys) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("清除剪贴板")).font(.headline)
                Text(L10n.text("选择需要清除的分类。分类设置本身不会被删除。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(keys, id: \.storageValue) { key in
                        Toggle(isOn: binding(for: key)) {
                            HStack(spacing: 8) {
                                Label(title(for: key), systemImage: symbol(for: key))
                                Spacer(minLength: 8)
                                Text("\(store.entryCount(matching: [key]))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)

            Divider()
            HStack(spacing: 10) {
                Text(selectedKeys.isEmpty ? L10n.text("至少选择一个分类") : L10n.format("清除记录数格式", removalCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(L10n.text("取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("清除所选分类"), role: .destructive) { onConfirm(selectedKeys) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedKeys.isEmpty || removalCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
    }

    private func binding(for key: ClipboardCategoryKey) -> Binding<Bool> {
        Binding(
            get: { selectedKeys.contains(key) },
            set: { selected in
                if selected { selectedKeys.insert(key) }
                else { selectedKeys.remove(key) }
            }
        )
    }

    private func title(for key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): category.displayName
        case .custom(let id): store.settings.customCategory(id: id)?.name ?? L10n.text("自定义分类")
        }
    }

    private func symbol(for key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): category.systemImage
        case .custom: "line.3.horizontal.decrease.circle"
        }
    }
}
