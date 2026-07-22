import AppKit
import HedgeMemoCore
import SwiftUI

private enum SettingsLayout {
    static let panelWidth: CGFloat = 504
    static let horizontalInset: CGFloat = 24
    static let labelColumnWidth: CGFloat = 142
    static let controlColumnWidth: CGFloat = 232
}

private enum AppVersion {
    static let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
}

/// Hosts the settings UI in a standalone translucent panel, opened from the status bar menu.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let clipboardStore: ClipboardHistoryStore
    private let screenshotSettingsStore: ScreenshotSettingsStore
    private let hotKeyWarnings: () -> [String]
    private var panel: NSPanel?

    init(
        clipboardStore: ClipboardHistoryStore,
        screenshotSettingsStore: ScreenshotSettingsStore,
        hotKeyWarnings: @escaping () -> [String]
    ) {
        self.clipboardStore = clipboardStore
        self.screenshotSettingsStore = screenshotSettingsStore
        self.hotKeyWarnings = hotKeyWarnings
    }

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // A plain titled window keeps the system's rounded corners, shadow and
        // a real title bar; translucency comes from the vibrancy background inside.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.panelWidth, height: 740),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        // A settings operation is deliberate. It should remain visible while
        // the user switches apps or opens a native picker, and only disappear
        // after an explicit close.
        panel.hidesOnDeactivate = false
        // Only the native title bar is draggable. Controls such as sliders,
        // toggles and menus must never steal their drag into a panel move.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let content = SettingsPanelView(
            clipboardStore: clipboardStore,
            screenshotSettingsStore: screenshotSettingsStore,
            hotKeyWarnings: hotKeyWarnings()
        )
        PanelMaterialHost.install(content, in: panel, cornerRadius: 16)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

struct SettingsPanelView: View {
    @ObservedObject var clipboardStore: ClipboardHistoryStore
    @ObservedObject var screenshotSettingsStore: ScreenshotSettingsStore
    let hotKeyWarnings: [String]
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var customDraft: CustomCategoryDraft?
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                clipboardSection
                appearanceSection
                codeAppearanceSection
                categorySection
                screenshotSection
                startupSection
                authorSection
                if hasHotKeyConflict || !hotKeyWarnings.isEmpty {
                    SettingsSection(title: "提醒") {
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
                }
            }
            .padding(.horizontal, SettingsLayout.horizontalInset)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        // Keep settings at macOS's compact inspector density while retaining
        // standard controls and their native focus/selection behavior.
        .controlSize(.small)
        .padding(.top, 32)
        .frame(width: SettingsLayout.panelWidth, height: 740)
        .onAppear {
            refreshAccessibilityTrust()
            launchAtLogin.refresh()
        }
        .sheet(item: $customDraft) { draft in
            CustomCategoryEditorSheet(draft: draft) { saveCustomCategory($0) }
        }
    }

    private var clipboardSection: some View {
        SettingsSection(title: "剪贴板历史") {
            SettingsFormRow("最多保存") {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(clipboardStore.settings.maxEntries) 条")
                        .monospacedDigit()
                    Slider(value: maxEntriesStepBinding, in: 0...Double(ClipboardHistorySettings.maxEntryChoices.count - 1), step: 1)
                        .frame(width: SettingsLayout.controlColumnWidth)
                        .accessibilityLabel("剪贴板最多保存条数")
                }
            }
            SettingsDivider()
            SettingsFormRow("保存图片") { Toggle("保存图片", isOn: savesImagesBinding).labelsHidden() }
            SettingsDivider()
            SettingsFormRow("复制后自动粘贴") { Toggle("复制后自动粘贴", isOn: autoPasteBinding).labelsHidden() }
            SettingsDivider()
            SettingsFormRow("剪贴板快捷键") { HotKeyRecorderControl(hotKey: clipboardHotKeyBinding).frame(width: 180, height: 28) }
            if clipboardStore.settings.autoPaste {
                SettingsDivider()
                SettingsRow { PermissionStatusRow(
                    isTrusted: accessibilityTrusted,
                    onRefresh: refreshAccessibilityTrust,
                    onRequest: requestAccessibilityTrust
                ) }
            }
            SettingsDivider()
            SettingsActionRow {
                Button(role: .destructive) {
                    clipboardStore.clearHistory()
                } label: {
                    Label("清空剪贴板历史", systemImage: "trash")
                }
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection(
            title: "外观",
            footer: "关闭后仍可正常滚动，只隐藏剪切板、表情包和其他界面的滚动条。"
        ) {
            SettingsFormRow("显示滚动条") {
                Toggle("显示滚动条", isOn: $showsScrollIndicators)
                    .labelsHidden()
                    .accessibilityHint("控制 HedgeMemo 所有可滚动内容的滚动条显示")
            }
        }
    }

    private var categorySection: some View {
        SettingsSection(title: "剪贴板分类", footer: "自定义分类按正则表达式筛选文本条目。") {
            let keys = clipboardStore.settings.orderedCategoryKeys
            ForEach(Array(keys.enumerated()), id: \.element.storageValue) { index, key in
                SettingsRow { categoryRow(key: key, index: index, total: keys.count) }
                if index != keys.count - 1 { SettingsDivider() }
            }
            SettingsDivider()
            SettingsActionRow {
                Button {
                    customDraft = CustomCategoryDraft()
                } label: {
                    Label("添加自定义分类…", systemImage: "plus")
                }
            }
        }
    }

    /// Keep syntax appearance separate from clipboard retention and category
    /// management. A native Picker gives the choice a visible label, keyboard
    /// navigation and an immediate, predictable preview effect.
    private var codeAppearanceSection: some View {
        SettingsSection(
            title: "代码显示",
            footer: "配色会立即应用到剪贴板列表、预览和固定到桌面的代码便签。"
        ) {
            SettingsFormRow("语法高亮配色") {
                Picker("语法高亮配色", selection: codeHighlightThemeBinding) {
                    ForEach(CodeHighlightTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190, alignment: .trailing)
                .accessibilityLabel("语法高亮配色")
                .accessibilityHint(clipboardStore.settings.resolvedCodeHighlightTheme.accessibilityDescription)
            }
        }
    }

    @ViewBuilder
    private func categoryRow(key: ClipboardCategoryKey, index: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            switch key {
            case .builtin(let category):
                Label(category.displayName, systemImage: category.systemImage)
            case .custom(let id):
                let custom = clipboardStore.settings.customCategory(id: id)
                Label(custom?.name ?? "自定义", systemImage: "tag")
                if let pattern = custom?.pattern {
                    Text(pattern)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Toggle("启用", isOn: Binding(
                get: { clipboardStore.settings.isCategoryEnabled(key) },
                set: { clipboardStore.setCategory(key, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help("关闭会清除该分类现有记录，并停止展示及记录此分类")
            if case .custom(let id) = key {
                HoverIconButton(systemImage: "pencil", help: "编辑") {
                    if let custom = clipboardStore.settings.customCategory(id: id) {
                        customDraft = CustomCategoryDraft(category: custom)
                    }
                }
                HoverIconButton(systemImage: "trash", tint: .red, help: "删除") {
                    deleteCustomCategory(id: id)
                }
            }
            HoverIconButton(systemImage: "chevron.up", help: "上移") {
                moveCategory(key, delta: -1)
            }
            .disabled(index == 0)
            .opacity(index == 0 ? 0.3 : 1)
            HoverIconButton(systemImage: "chevron.down", help: "下移") {
                moveCategory(key, delta: 1)
            }
            .disabled(index == total - 1)
            .opacity(index == total - 1 ? 0.3 : 1)
        }
    }

    private func moveCategory(_ key: ClipboardCategoryKey, delta: Int) {
        var order = clipboardStore.settings.orderedCategoryKeys
        guard let index = order.firstIndex(of: key) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        clipboardStore.settings.categoryOrder = order.map(\.storageValue)
    }

    private func saveCustomCategory(_ category: CustomClipboardCategory) {
        var customs = clipboardStore.settings.customCategories ?? []
        if let index = customs.firstIndex(where: { $0.id == category.id }) {
            customs[index] = category
        } else {
            customs.append(category)
        }
        clipboardStore.settings.customCategories = customs
    }

    private func deleteCustomCategory(id: UUID) {
        clipboardStore.setCategory(.custom(id), enabled: false)
        var customs = clipboardStore.settings.customCategories ?? []
        customs.removeAll { $0.id == id }
        clipboardStore.settings.customCategories = customs
    }

    private var screenshotSection: some View {
        SettingsSection(title: "截图") {
            SettingsFormRow("默认模式") { Picker("默认模式", selection: screenshotModeBinding) {
                ForEach(ScreenshotMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190, alignment: .trailing) }
            SettingsDivider()
            SettingsFormRow("截图快捷键") { HotKeyRecorderControl(hotKey: screenshotHotKeyBinding).frame(width: 180, height: 28) }
            SettingsDivider()
            SettingsFormRow("记住上次模式") { Toggle("记住上次模式", isOn: remembersScreenshotModeBinding).labelsHidden() }
            SettingsDivider()
            SettingsFormRow("截图后打开编辑") { Toggle("截图后打开编辑", isOn: opensEditorAfterCaptureBinding).labelsHidden() }
        }
    }

    private var startupSection: some View {
        SettingsSection(title: "启动") {
            SettingsFormRow("登录时自动启动") {
                Toggle("登录时自动启动 HedgeMemo", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )).labelsHidden()
            }
            if let statusMessage = launchAtLogin.statusMessage {
                SettingsDivider()
                SettingsRow {
                    Label(statusMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var authorSection: some View {
        SettingsSection(title: "关于作者") {
            SettingsFormRow("版本") {
                Text(AppVersion.display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            SettingsFormRow("作者") { Text("ZonnL") }
            SettingsDivider()
            SettingsFormRow("邮箱") { Link("zonn.l@foxmail.com", destination: URL(string: "mailto:zonn.l@foxmail.com")!) }
            SettingsDivider()
            SettingsFormRow("GitHub") { Link("Again0521/hedgememo", destination: URL(string: "https://github.com/Again0521/hedgememo")!) }
        }
    }

    private var maxEntriesBinding: Binding<Int> {
        Binding(
            get: { clipboardStore.settings.maxEntries },
            set: { clipboardStore.settings.maxEntries = $0 }
        )
    }

    /// Slider positions are deliberately discrete: the product limit is a
    /// documented total cap rather than an arbitrary number field.
    private var maxEntriesStepBinding: Binding<Double> {
        Binding(
            get: {
                let choices = ClipboardHistorySettings.maxEntryChoices
                let nearest = choices.enumerated().min { abs($0.element - clipboardStore.settings.maxEntries) < abs($1.element - clipboardStore.settings.maxEntries) }?.offset ?? 0
                return Double(nearest)
            },
            set: { step in
                let choices = ClipboardHistorySettings.maxEntryChoices
                let index = min(max(Int(step.rounded()), 0), choices.count - 1)
                clipboardStore.settings.maxEntries = choices[index]
            }
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

    private var codeHighlightThemeBinding: Binding<CodeHighlightTheme> {
        Binding(
            get: { clipboardStore.settings.resolvedCodeHighlightTheme },
            set: { clipboardStore.settings.codeHighlightTheme = $0 }
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

/// Settings deliberately use the window's single vibrancy surface. Section
/// structure comes from typography and separators, not a second translucent
/// card layered on top of the window material.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) { content }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

/// Buttons perform a discrete action, so they share the same right control
/// column as menus, switches and shortcut recorders instead of floating left.
private struct SettingsActionRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .frame(width: SettingsLayout.controlColumnWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
    }
}

/// Fixed label column for every form-like setting.  This prevents switches,
/// shortcuts, pickers and values from drifting horizontally between sections.
private struct SettingsFormRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .frame(width: SettingsLayout.labelColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            content
                .frame(width: SettingsLayout.controlColumnWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider() }
}

struct CustomCategoryDraft: Identifiable {
    let id: UUID
    var name: String
    var pattern: String
    let isNew: Bool

    init() {
        id = UUID()
        name = ""
        pattern = ""
        isNew = true
    }

    init(category: CustomClipboardCategory) {
        id = category.id
        name = category.name
        pattern = category.pattern
        isNew = false
    }
}

private struct CustomCategoryEditorSheet: View {
    @State var draft: CustomCategoryDraft
    let onSave: (CustomClipboardCategory) -> Void
    @Environment(\.dismiss) private var dismiss

    private var category: CustomClipboardCategory {
        CustomClipboardCategory(id: draft.id, name: draft.name, pattern: draft.pattern)
    }

    private var isPatternValid: Bool { category.isPatternValid }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && isPatternValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.isNew ? "新建自定义分类" : "编辑自定义分类")
                .font(.headline)
            TextField("分类名称", text: $draft.name)
            TextField("正则表达式，例如 ^\\d{6}$", text: $draft.pattern)
                .font(.system(size: 12, design: .monospaced))
            if !draft.pattern.isEmpty && !isPatternValid {
                Label("正则表达式无效", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(category)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 320)
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

private struct HotKeyRecorderControl: View {
    @Binding var hotKey: HotKeyDefinition
    @State private var isRecording = false

    var body: some View {
        HotKeyRecorderButton(hotKey: $hotKey, isRecording: $isRecording)
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

extension HotKeyDefinition {
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
