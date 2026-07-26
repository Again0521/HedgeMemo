import AppKit
import HedgeMemoCore
import SwiftUI

enum SettingsLayout {
    static let panelWidth: CGFloat = 720
    static let panelHeight: CGFloat = 620
    static let sidebarWidth: CGFloat = 184
    static let horizontalInset: CGFloat = 24
    static let labelColumnWidth: CGFloat = 142
    static let controlColumnWidth: CGFloat = 232
    /// Clears the transparent title bar so the floating sidebar and the content
    /// header both begin below the traffic lights.
    static let titleBarInset: CGFloat = 36
    static let sidebarCornerRadius: CGFloat = 12
}

/// Top-level settings destinations. Each of the app's three features owns its
/// own pane, with shared preferences collected under "通用", so a setting is
/// found where its feature lives instead of in one long scroll.
enum SettingsTab: String, CaseIterable, Identifiable {
    case clipboard
    case screenshot
    case memePanel
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: L10n.text("剪贴板")
        case .screenshot: L10n.text("截图")
        case .memePanel: L10n.text("表情包")
        case .general: L10n.text("通用")
        }
    }

    var systemImage: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .screenshot: "crop"
        case .memePanel: "face.smiling"
        case .general: "gearshape"
        }
    }
}

/// Hosts the settings UI in a standalone translucent panel, opened from the status bar menu.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let clipboardStore: ClipboardHistoryStore
    private let screenshotSettingsStore: ScreenshotSettingsStore
    private let memePanelSettingsStore: MemePanelSettingsStore
    private let updateCheckStore: UpdateCheckStore
    private let lockStore: AppLockStore
    private let hotKeyWarnings: () -> [String]
    private var panel: NSPanel?

    init(
        clipboardStore: ClipboardHistoryStore,
        screenshotSettingsStore: ScreenshotSettingsStore,
        memePanelSettingsStore: MemePanelSettingsStore,
        updateCheckStore: UpdateCheckStore,
        lockStore: AppLockStore,
        hotKeyWarnings: @escaping () -> [String]
    ) {
        self.clipboardStore = clipboardStore
        self.screenshotSettingsStore = screenshotSettingsStore
        self.memePanelSettingsStore = memePanelSettingsStore
        self.updateCheckStore = updateCheckStore
        self.lockStore = lockStore
        self.hotKeyWarnings = hotKeyWarnings
    }

    func show() {
        updateCheckStore.acknowledgeUpdateBadge()
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // A plain titled window keeps the system's rounded corners, shadow and
        // a real title bar; translucency comes from the vibrancy background inside.
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayout.panelWidth,
                height: SettingsLayout.panelHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("设置")
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
            memePanelSettingsStore: memePanelSettingsStore,
            updateCheckStore: updateCheckStore,
            lockStore: lockStore,
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
    @ObservedObject var memePanelSettingsStore: MemePanelSettingsStore
    @ObservedObject var updateCheckStore: UpdateCheckStore
    @ObservedObject var lockStore: AppLockStore
    let hotKeyWarnings: [String]
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var customDraft: CustomCategoryDraft?
    @State private var customCategoryError: String?
    @State private var selectedTab: SettingsTab = .clipboard
    @State private var isSettingPIN = false
    @State private var isVerifyingPIN = false
    @State private var biometricsAvailable = BiometricAuthenticator.isAvailable
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true
    @AppStorage(AppPreferences.interfaceOpacityKey)
    private var interfaceOpacity = AppPreferences.defaultInterfaceOpacity
    @AppStorage(AppLanguage.preferenceKey)
    private var languageRawValue = AppLanguage.current.rawValue

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        // Keep settings at macOS's compact inspector density while retaining
        // standard controls and their native focus/selection behavior.
        .controlSize(.small)
        .frame(width: SettingsLayout.panelWidth, height: SettingsLayout.panelHeight)
        .onAppear {
            refreshAccessibilityTrust()
            launchAtLogin.refresh()
            biometricsAvailable = BiometricAuthenticator.isAvailable
        }
        .onReceive(NotificationCenter.default.publisher(for: .hedgeMemoBiometricAvailabilityDidChange)) { _ in
            biometricsAvailable = BiometricAuthenticator.isAvailable
        }
        .sheet(item: $customDraft) { draft in
            CustomCategoryEditorSheet(
                draft: draft,
                recentApplications: recentSourceApplications
            ) {
                saveCustomCategory($0)
            }
        }
        .sheet(isPresented: $isSettingPIN) {
            // Nothing to enable afterwards: a surface is locked purely by being
            // selected in the chips below, so creating the PIN is the whole step.
            PINSetupSheet(lockStore: lockStore) { _ in }
        }
        .sheet(isPresented: $isVerifyingPIN) {
            PINVerifySheet(lockStore: lockStore)
        }
        .alert(
            L10n.text("无法保存分类"),
            isPresented: Binding(
                get: { customCategoryError != nil },
                set: { if !$0 { customCategoryError = nil } }
            )
        ) {
            Button(L10n.text("好")) { customCategoryError = nil }
        } message: {
            Text(customCategoryError ?? "")
        }
    }

    /// Managing the PIN is only offered once the user has proved they know it.
    /// Without this, anyone at an unattended Mac could strip the protection off
    /// the encrypted 密码 category without ever entering the PIN.
    private var requiresUnlockToManagePIN: Bool {
        lockStore.hasPIN
            && !lockStore.settings.lockedCategoryKeys.isEmpty
            && lockStore.isLocked
    }

    /// The feature switcher is its own surface floating over the window's
    /// material — deliberately the *same* native glass sample (SystemGlassCard),
    /// not a tinted or opaque sidebar, so the panel still reads as one material
    /// with a raised layer rather than two different products.
    private var sidebar: some View {
        // The card hugs its rows instead of stretching: a switcher with four
        // destinations should not paint an empty column down to the window
        // bottom. `frame(maxHeight:alignment:)` on the *outer* column is what
        // keeps the hugged card pinned under the title bar.
        SystemGlassCard(cornerRadius: SettingsLayout.sidebarCornerRadius) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabRow(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        // 软件更新 lives under 通用, so that is where the dot
                        // points the user when a newer version exists.
                        showsUpdateDot: tab == .general && updateCheckStore.hasAvailableUpdate
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(8)
            .frame(width: SettingsLayout.sidebarWidth, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.sidebarCornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.55), lineWidth: 1)
        )
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, SettingsLayout.titleBarInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedTab.title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, SettingsLayout.horizontalInset)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selectedTab {
                    case .clipboard: clipboardTab
                    case .screenshot: screenshotTab
                    case .memePanel: memePanelTab
                    case .general: generalTab
                    }
                }
                .padding(.horizontal, SettingsLayout.horizontalInset)
                .padding(.bottom, 24)
            }
            .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SettingsLayout.titleBarInset)
    }

    @ViewBuilder
    private var clipboardTab: some View {
        clipboardSection
        ClipboardAppFilterSettingsView(store: clipboardStore)
        codeAppearanceSection
        categorySection
    }

    /// The lock spans the clipboard's 密码 category and the meme panel, so it
    /// belongs in 通用 rather than inside any one feature's pane.
    private var securitySection: some View {
        SettingsSection(
            title: L10n.text("安全"),
            footer: L10n.text("密码管理器等标记为隐私的复制内容会记录到「密码」分类并加密保存；该分类始终需要 PIN 码解锁。关闭后这类内容将完全不被记录。")
        ) {
            SettingsActionRow {
                HStack(spacing: 8) {
                    if requiresUnlockToManagePIN {
                        // While something is still locked, managing the PIN has
                        // to be earned. Changing it is gated too: otherwise
                        // "change" would be a way around "remove" — set a PIN
                        // you know, then remove it.
                        Button(L10n.text("解锁")) { isVerifyingPIN = true }
                    } else {
                        Button(L10n.text(lockStore.hasPIN ? "修改 PIN 码…" : "设置 PIN 码…")) {
                            isSettingPIN = true
                        }
                        if lockStore.hasPIN {
                            Button(L10n.text("移除 PIN 码"), role: .destructive) {
                                try? lockStore.removePIN()
                            }
                        }
                    }
                }
            }
            SettingsDivider()
            // Selecting a chip *is* switching the lock on for that surface —
            // there is no separate master toggle to contradict it.
            SettingsRow {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("需要锁定的分类"))
                    LockTargetChips(
                        targets: lockTargets,
                        isLocked: { lockStore.settings.lockedCategoryKeys.contains($0.storageValue) },
                        isFixed: { $0.storageValue == ClipboardCategoryKey.builtin(.password).storageValue },
                        toggle: toggleLockTarget
                    )
                }
                .padding(.vertical, 4)
            }
            SettingsDivider()
            SettingsFormRow(L10n.text("锁定时机")) {
                Picker(L10n.text("锁定时机"), selection: lockTimingBinding) {
                    ForEach(AppLockTiming.allCases, id: \.self) { timing in
                        Text(timing.displayName).tag(timing)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: SettingsLayout.controlColumnWidth, alignment: .trailing)
            }
            SettingsDivider()
            SettingsFormRow(L10n.text("允许触控 ID 解锁")) {
                Toggle(L10n.text("允许触控 ID 解锁"), isOn: biometricsBinding)
                    .labelsHidden()
                    .disabled(!biometricsAvailable)
            }
            SettingsDivider()
            SettingsFormRow(L10n.text("记录密码类内容")) {
                Toggle(L10n.text("记录密码类内容"), isOn: capturesPasswordsBinding)
                    .labelsHidden()
            }
        }
    }

    /// Every surface the lock can cover: the clipboard categories plus the meme
    /// panel, which is not a category but is lockable all the same.
    private var lockTargets: [LockTarget] {
        clipboardStore.settings.orderedCategoryKeys.map {
            LockTarget(storageValue: $0.storageValue, name: categoryDisplayName($0))
        } + [LockTarget(
            storageValue: AppLockSettings.memePanelStorageKey,
            name: L10n.text("表情包面板")
        )]
    }

    private func toggleLockTarget(_ target: LockTarget) {
        // 密码 holds nothing but secrets; its gate is not optional.
        guard target.storageValue != ClipboardCategoryKey.builtin(.password).storageValue else { return }
        let locked = lockStore.settings.lockedCategoryKeys.contains(target.storageValue)
        if target.storageValue == AppLockSettings.memePanelStorageKey {
            lockStore.settings.setMemePanelLocked(!locked)
        } else if let key = ClipboardCategoryKey(storageValue: target.storageValue) {
            lockStore.settings.setCategory(key, locked: !locked)
        }
    }

    private var lockableCategoryKeys: [ClipboardCategoryKey] {
        clipboardStore.settings.orderedCategoryKeys
    }

    private func categoryDisplayName(_ key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): return category.displayName
        case .custom(let id): return clipboardStore.settings.customCategory(id: id)?.name ?? L10n.text("自定义")
        }
    }

    private var lockTimingBinding: Binding<AppLockTiming> {
        Binding(
            get: { lockStore.settings.timing },
            set: { lockStore.settings.timing = $0 }
        )
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { lockStore.settings.allowsBiometrics },
            set: { lockStore.settings.allowsBiometrics = $0 }
        )
    }

    private var capturesPasswordsBinding: Binding<Bool> {
        Binding(
            get: { lockStore.settings.capturesPasswords },
            set: { enabled in
                lockStore.settings.capturesPasswords = enabled
                // Turning capture on with the 密码 category switched off would
                // record entries the user could never reach. Turning it back off
                // deliberately does *not* disable the category, because that
                // path is destructive — it would delete passwords already saved.
                if enabled { clipboardStore.setCategory(.builtin(.password), enabled: true) }
            }
        )
    }

    @ViewBuilder
    private var screenshotTab: some View {
        screenshotSection
    }

    @ViewBuilder
    private var memePanelTab: some View {
        memePanelSection
    }

    @ViewBuilder
    private var generalTab: some View {
        languageSection
        securitySection
        appearanceSection
        startupSection
        updateSection
        authorSection
        remindersSection
    }

    /// Shortcut conflicts span several features, so they stay in one shared
    /// place rather than being repeated in each feature's pane.
    @ViewBuilder
    private var remindersSection: some View {
        if !hotKeyConflictMessages.isEmpty || !hotKeyWarnings.isEmpty {
            SettingsSection(title: L10n.text("提醒")) {
                ForEach(hotKeyConflictMessages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
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

    private var languageSection: some View {
        SettingsSection(title: L10n.text("语言")) {
            SettingsFormRow(L10n.text("语言")) {
                Picker(L10n.text("语言"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190, alignment: .trailing)
                .accessibilityLabel(L10n.text("语言"))
            }
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { languageRawValue },
            set: { rawValue in
                guard let language = AppLanguage(rawValue: rawValue) else { return }
                AppLanguage.select(language)
                languageRawValue = language.rawValue
            }
        )
    }

    private var clipboardSection: some View {
        SettingsSection(title: L10n.text("剪贴板历史")) {
            SettingsFormRow(L10n.text("最多保存")) {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(L10n.format("保留条数格式", clipboardStore.settings.maxEntries))
                        .monospacedDigit()
                    Slider(value: maxEntriesStepBinding, in: 0...Double(ClipboardHistorySettings.maxEntryChoices.count - 1), step: 1)
                        .frame(width: SettingsLayout.controlColumnWidth)
                        .accessibilityLabel(L10n.text("剪贴板最多保存条数"))
                }
            }
            SettingsDivider()
            SettingsFormRow(L10n.text("保存图片")) { Toggle(L10n.text("保存图片"), isOn: savesImagesBinding).labelsHidden() }
            SettingsDivider()
            SettingsFormRow(L10n.text("复制后自动粘贴")) { Toggle(L10n.text("复制后自动粘贴"), isOn: autoPasteBinding).labelsHidden() }
            SettingsDivider()
            SettingsFormRow(L10n.text("剪贴板快捷键")) { HotKeyRecorderControl(hotKey: clipboardHotKeyBinding).frame(width: 180, height: 28) }
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
                    ClipboardClearSelectionPanel.run(store: clipboardStore)
                } label: {
                    Label(L10n.text("清除剪贴板历史…"), systemImage: "trash")
                }
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection(
            title: L10n.text("外观"),
            footer: L10n.text("0% 保留清晰的系统玻璃效果，100% 完全关闭透明效果；菜单栏弹窗不受影响。")
        ) {
            SettingsFormRow(L10n.text("软件不透明度")) {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 10) {
                        Text("\(interfaceOpacityPercent)%")
                            .monospacedDigit()
                        Button(L10n.text("恢复默认")) {
                            interfaceOpacity = AppPreferences.defaultInterfaceOpacity
                        }
                        .disabled(
                            abs(interfaceOpacity - AppPreferences.defaultInterfaceOpacity)
                                < 0.005
                        )
                    }
                    Slider(
                        value: interfaceOpacityPercentBinding,
                        in: 0...100,
                        step: 1
                    )
                    .accessibilityLabel(L10n.text("软件不透明度"))
                    .accessibilityValue("\(interfaceOpacityPercent)%")
                    .accessibilityHint(L10n.text("调节菜单栏弹窗以外面板的不透明度"))
                }
            }
            SettingsDivider()
            SettingsFormRow(L10n.text("显示滚动条")) {
                Toggle(L10n.text("显示滚动条"), isOn: $showsScrollIndicators)
                    .labelsHidden()
                    .accessibilityHint(L10n.text("控制 HedgeMemo 所有可滚动内容的滚动条显示"))
            }
        }
    }

    private var interfaceOpacityPercent: Int {
        Int((AppPreferences.clampedInterfaceOpacity(interfaceOpacity) * 100).rounded())
    }

    private var interfaceOpacityPercentBinding: Binding<Double> {
        Binding(
            get: {
                AppPreferences.clampedInterfaceOpacity(interfaceOpacity) * 100
            },
            set: {
                interfaceOpacity = AppPreferences.clampedInterfaceOpacity($0 / 100)
            }
        )
    }

    private var categorySection: some View {
        SettingsSection(title: L10n.text("剪贴板分类"), footer: L10n.text("自定义分类可组合内容、来源应用和内容类型等条件。")) {
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
                    Label(L10n.text("添加自定义分类…"), systemImage: "plus")
                }
            }
        }
    }

    /// Keep syntax appearance separate from clipboard retention and category
    /// management. A native Picker gives the choice a visible label, keyboard
    /// navigation and an immediate, predictable preview effect.
    private var codeAppearanceSection: some View {
        SettingsSection(
            title: L10n.text("代码显示"),
            footer: L10n.text("配色会立即应用到剪贴板列表、预览和固定到桌面的代码便签。")
        ) {
            SettingsFormRow(L10n.text("语法高亮配色")) {
                Picker(L10n.text("语法高亮配色"), selection: codeHighlightThemeBinding) {
                    ForEach(CodeHighlightTheme.allCases, id: \.self) { theme in
                        Text(L10n.text(theme.displayName)).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190, alignment: .trailing)
                .accessibilityLabel(L10n.text("语法高亮配色"))
                .accessibilityHint(L10n.text(clipboardStore.settings.resolvedCodeHighlightTheme.accessibilityDescription))
            }
        }
    }

    @ViewBuilder
    private func categoryRow(key: ClipboardCategoryKey, index: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            switch key {
            case .builtin(let category):
                categoryLabel(title: L10n.text(category.displayName), systemImage: category.systemImage)
            case .custom(let id):
                let custom = clipboardStore.settings.customCategory(id: id)
                categoryLabel(title: custom?.name ?? L10n.text("自定义"), systemImage: "tag")
                if let custom {
                    Text(ruleSummary(for: custom))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if case .custom(let id) = key {
                HoverIconButton(systemImage: "pencil", help: L10n.text("编辑")) {
                    if let custom = clipboardStore.settings.customCategory(id: id) {
                        customDraft = CustomCategoryDraft(category: custom)
                    }
                }
                HoverIconButton(systemImage: "trash", tint: .red, help: L10n.text("删除")) {
                    deleteCustomCategory(id: id)
                }
            }
            HoverIconButton(systemImage: "chevron.up", help: L10n.text("上移")) {
                moveCategory(key, delta: -1)
            }
            .disabled(index == 0)
            .opacity(index == 0 ? 0.3 : 1)
            HoverIconButton(systemImage: "chevron.down", help: L10n.text("下移")) {
                moveCategory(key, delta: 1)
            }
            .disabled(index == total - 1)
            .opacity(index == total - 1 ? 0.3 : 1)
            Toggle(L10n.text("启用"), isOn: Binding(
                get: { clipboardStore.settings.isCategoryEnabled(key) },
                set: { clipboardStore.setCategory(key, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(L10n.text("关闭会清除该分类现有记录，并停止展示及记录此分类"))
        }
    }

    private func categoryLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 28, height: 20, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }

    private func moveCategory(_ key: ClipboardCategoryKey, delta: Int) {
        var order = clipboardStore.settings.orderedCategoryKeys
        guard let index = order.firstIndex(of: key) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        clipboardStore.settings.categoryOrder = order.map(\.storageValue)
    }

    private func ruleSummary(for category: CustomClipboardCategory) -> String {
        let rules = category.effectiveRules
        guard let first = rules.first else { return L10n.text("未设置条件") }
        let value = first.displayValue ?? first.value
        let prefix = first.isNegated ? L10n.text("排除") + " " : ""
        let firstSummary = "\(prefix)\(first.kind.displayName): \(value)"
        guard rules.count > 1 else { return firstSummary }
        return L10n.format("%@，另有 %d 条", firstSummary, rules.count - 1)
    }

    private var recentSourceApplications: [ClipboardSourceApplication] {
        var seen = Set<String>()
        return clipboardStore.entries
            .compactMap(\.sourceApplication)
            .filter { seen.insert($0.stableIdentifier).inserted }
            .prefix(20)
            .map { $0 }
    }

    @discardableResult
    private func saveCustomCategory(_ category: CustomClipboardCategory) -> Bool {
        var category = category
        category.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try category.validate()
        } catch {
            customCategoryError = error.localizedDescription
            return false
        }
        var customs = clipboardStore.settings.customCategories ?? []
        if let index = customs.firstIndex(where: { $0.id == category.id }) {
            customs[index] = category
        } else {
            customs.append(category)
        }
        clipboardStore.settings.customCategories = customs
        return true
    }

    private func deleteCustomCategory(id: UUID) {
        clipboardStore.setCategory(.custom(id), enabled: false)
        var customs = clipboardStore.settings.customCategories ?? []
        customs.removeAll { $0.id == id }
        clipboardStore.settings.customCategories = customs
    }

    private var screenshotSection: some View {
        SettingsSection(title: L10n.text("截图")) {
            SettingsFormRow(L10n.text("默认模式")) { Picker(L10n.text("默认模式"), selection: screenshotModeBinding) {
                ForEach(ScreenshotMode.allCases, id: \.self) { mode in
                    Text(L10n.text(mode.displayName)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190, alignment: .trailing) }
            SettingsDivider()
            SettingsFormRow(L10n.text("截图快捷键")) { HotKeyRecorderControl(hotKey: screenshotHotKeyBinding).frame(width: 180, height: 28) }
            SettingsDivider()
            SettingsFormRow(L10n.text("记住上次模式")) { Toggle(L10n.text("记住上次模式"), isOn: remembersScreenshotModeBinding).labelsHidden() }
            SettingsDivider()
            SettingsFormRow(L10n.text("截图后打开编辑")) { Toggle(L10n.text("截图后打开编辑"), isOn: opensEditorAfterCaptureBinding).labelsHidden() }
        }
    }

    private var memePanelSection: some View {
        SettingsSection(title: L10n.text("表情包面板"), footer: L10n.text("按下快捷键后，面板会出现在鼠标附近；复制表情包或点击面板外会自动收起。")) {
            SettingsFormRow(L10n.text("唤醒快捷键")) {
                HotKeyRecorderControl(hotKey: memePanelHotKeyBinding)
                    .frame(width: 180, height: 28)
            }
        }
    }

    private var startupSection: some View {
        SettingsSection(title: L10n.text("启动")) {
            SettingsFormRow(L10n.text("登录时自动启动")) {
                Toggle(L10n.text("登录时自动启动 HedgeMemo"), isOn: Binding(
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
        SettingsSection(title: L10n.text("关于作者")) {
            SettingsFormRow(L10n.text("版本")) {
                Text(AppVersion.display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            SettingsFormRow(L10n.text("作者")) { Text("ZonnL") }
            SettingsDivider()
            SettingsFormRow(L10n.text("邮箱")) { Link("zonn.l@foxmail.com", destination: URL(string: "mailto:zonn.l@foxmail.com")!) }
            SettingsDivider()
            SettingsFormRow("GitHub") { Link("Again0521/hedgememo", destination: URL(string: "https://github.com/Again0521/hedgememo")!) }
        }
    }

    private var updateSection: some View {
        SettingsSection(title: L10n.text("软件更新")) {
            SettingsFormRow(L10n.text("当前版本")) {
                Text(AppVersion.display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            if let release = updateCheckStore.availableRelease {
                SettingsFormRow(L10n.text("发现新版本")) {
                    Link(destination: release.pageURL) {
                        Text("v\(release.version.displayString)")
                            .monospacedDigit()
                    }
                    .help(L10n.format("打开版本下载页面格式", release.title))
                    .accessibilityHint(L10n.text("在浏览器中打开新版本下载页面"))
                }
                SettingsDivider()
            }
            SettingsRow {
                HStack(spacing: 12) {
                    Text(updateStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(updateStatusText)
                    Spacer(minLength: 12)
                    Button {
                        updateCheckStore.checkNow()
                    } label: {
                        if updateCheckStore.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 72)
                        } else {
                            Label(L10n.text("检查更新"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(updateCheckStore.isChecking)
                    .fixedSize()
                }
            }
        }
    }

    private var updateStatusText: String {
        if updateCheckStore.isChecking { return L10n.text("正在检查更新…") }
        switch updateCheckStore.result {
        case .idle:
            return L10n.text("每日首次启动时自动检查一次")
        case .upToDate:
            return L10n.text("当前已是最新版本。")
        case .updateAvailable:
            return L10n.text("发现新版本，点击版本号前往下载。")
        case .failed:
            return L10n.text("暂时无法检查更新，请稍后重试。")
        }
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

    private var memePanelHotKeyBinding: Binding<HotKeyDefinition> {
        Binding(
            get: { memePanelSettingsStore.settings.hotKey },
            set: { memePanelSettingsStore.settings.hotKey = $0 }
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

    private var hotKeyConflictMessages: [String] {
        let hotKeys = [
            (L10n.text("剪贴板"), clipboardStore.settings.hotKey ?? .defaultClipboard),
            (L10n.text("截图"), screenshotSettingsStore.settings.hotKey ?? .defaultScreenshot),
            (L10n.text("表情包面板"), memePanelSettingsStore.settings.hotKey),
        ]
        var messages = [String]()
        for index in hotKeys.indices {
            for other in hotKeys.dropFirst(index + 1) {
                if HotKeyPolicy.conflicts(hotKeys[index].1, other.1) {
                    messages.append(L10n.format("快捷键冲突格式", hotKeys[index].0, other.0))
                }
            }
        }
        return messages
    }

    private func refreshAccessibilityTrust() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func requestAccessibilityTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }
}

/// A surface the PIN lock can cover. Identified by its storage value so a
/// clipboard category and the meme panel can share one row of chips.
struct LockTarget: Identifiable, Hashable {
    let storageValue: String
    let name: String
    var id: String { storageValue }
}

/// Locked surfaces are picked as a wrapping row of chips rather than a column of
/// checkboxes: selection *is* the lock, so a filled accent chip reads as "this
/// one is locked" without a second switch to contradict it.
private struct LockTargetChips: View {
    let targets: [LockTarget]
    let isLocked: (LockTarget) -> Bool
    let isFixed: (LockTarget) -> Bool
    let toggle: (LockTarget) -> Void

    var body: some View {
        ChipFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(targets) { target in
                let locked = isLocked(target)
                let fixed = isFixed(target)
                Button {
                    toggle(target)
                } label: {
                    Text(target.name)
                        .font(.system(size: 12, weight: locked ? .semibold : .regular))
                        .foregroundStyle(locked ? Color.white : Color.primary)
                        // No `lineLimit`/`maxWidth`: the layout gives each chip
                        // exactly the width its label needs, so a longer name
                        // like 表情包面板 is never truncated to an ellipsis.
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(
                            Capsule(style: .continuous)
                                .fill(locked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                // 密码 is always locked, so its chip shows the state but does
                // not invite a tap that would do nothing.
                .disabled(fixed)
                .help(fixed ? L10n.text("密码分类始终锁定") : target.name)
            }
        }
    }
}

/// Wraps chips onto as many lines as they need, each at its own natural width.
/// `LazyVGrid`'s adaptive columns force every cell to a shared column width,
/// which is what truncated the longer labels.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.height
        } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item { let index: Int; let size: CGSize }
    private struct Row { var items: [Item] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(Item(index: index, size: size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// One destination in the floating sidebar. Selection uses the system accent
/// color and hover uses a semantic material state, matching `CategoryChip` in
/// the other panels — no custom fills that would fight the glass surface.
private struct SettingsTabRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    var showsUpdateDot = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsUpdateDot {
                    Circle()
                        .fill(Color.red)
                        // On the accent-filled selected row a plain red dot
                        // muddies into the fill, so give it a matching rim.
                        .overlay(Circle().strokeBorder(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(L10n.text("有新版本"))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundStyle)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var backgroundStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isHovering { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(Color.clear)
    }
}

/// Settings deliberately use the window's single vibrancy surface. Section
/// structure comes from typography and separators, not a second translucent
/// card layered on top of the window material.
struct SettingsSection<Content: View>: View {
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

struct SettingsRow<Content: View>: View {
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
struct SettingsActionRow<Content: View>: View {
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
struct SettingsFormRow<Content: View>: View {
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

struct SettingsDivider: View {
    var body: some View { Divider() }
}

struct CustomCategoryDraft: Identifiable {
    let id: UUID
    var name: String
    var matchMode: ClipboardRuleMatchMode
    var rules: [ClipboardClassificationRule]
    let isNew: Bool

    init() {
        id = UUID()
        name = ""
        matchMode = .all
        rules = [ClipboardClassificationRule(kind: .contains)]
        isNew = true
    }

    init(category: CustomClipboardCategory) {
        id = category.id
        name = category.name
        matchMode = category.resolvedMatchMode
        rules = category.effectiveRules
        isNew = false
    }
}

private struct CustomCategoryEditorSheet: View {
    @State var draft: CustomCategoryDraft
    let recentApplications: [ClipboardSourceApplication]
    let onSave: (CustomClipboardCategory) -> Bool
    @Environment(\.dismiss) private var dismiss

    private var category: CustomClipboardCategory {
        CustomClipboardCategory(
            id: draft.id,
            name: draft.name,
            matchMode: draft.matchMode,
            rules: draft.rules
        )
    }

    private var validationError: String? {
        do {
            try category.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(draft.isNew ? "新建自定义分类" : "编辑自定义分类"))
                .font(.headline)
            TextField(L10n.text("分类名称"), text: $draft.name)

            Picker(L10n.text("匹配方式"), selection: $draft.matchMode) {
                ForEach(ClipboardRuleMatchMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($draft.rules) { $rule in
                        classificationRuleRow(rule: $rule)
                    }
                }
            }
            .frame(maxHeight: 340)

            HStack {
                Menu {
                    ForEach(ClipboardClassificationRuleKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) {
                            draft.rules.append(defaultRule(kind))
                        }
                    }
                } label: {
                    Label(L10n.text("添加条件"), systemImage: "plus")
                }
                .disabled(draft.rules.count >= 8)
                Spacer()
                Text(L10n.format("%d / 8 条条件", draft.rules.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L10n.text("取消")) { dismiss() }
                Button(L10n.text("保存")) {
                    if onSave(category) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func classificationRuleRow(
        rule: Binding<ClipboardClassificationRule>
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(L10n.text("排除"), isOn: rule.isNegated)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(L10n.text("排除满足此条件的条目"))

            Picker(L10n.text("条件"), selection: rule.kind) {
                ForEach(ClipboardClassificationRuleKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .onChange(of: rule.wrappedValue.kind) { _, kind in
                let replacement = defaultRule(kind)
                rule.wrappedValue.value = replacement.value
                rule.wrappedValue.displayValue = nil
                rule.wrappedValue.isCaseSensitive = false
            }

            ruleValueEditor(rule: rule)

            if [.contains, .startsWith, .endsWith, .regularExpression]
                .contains(rule.wrappedValue.kind) {
                Toggle(L10n.text("区分大小写"), isOn: rule.isCaseSensitive)
                    .toggleStyle(.checkbox)
                    .help(L10n.text("区分大小写"))
            }

            Button {
                draft.rules.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.text("删除条件"))
        }
        .padding(8)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func ruleValueEditor(
        rule: Binding<ClipboardClassificationRule>
    ) -> some View {
        switch rule.wrappedValue.kind {
        case .contentType:
            Picker(L10n.text("内容类型"), selection: rule.value) {
                ForEach(
                    ClipboardContentCategory.allCases.filter { $0 != .password },
                    id: \.rawValue
                ) { category in
                    Text(category.displayName).tag(category.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        case .sourceApplication:
            HStack(spacing: 4) {
                TextField(
                    L10n.text("应用名称或 Bundle ID"),
                    text: Binding(
                        get: { rule.wrappedValue.value },
                        set: {
                            rule.wrappedValue.value = $0
                            rule.wrappedValue.displayValue = nil
                        }
                    )
                )
                if !recentApplications.isEmpty {
                    Menu {
                        ForEach(recentApplications) { application in
                            Button(application.displayName) {
                                rule.wrappedValue.value = application.bundleIdentifier
                                    ?? application.stableIdentifier
                                rule.wrappedValue.displayValue = application.displayName
                            }
                        }
                    } label: {
                        Image(systemName: "app.badge")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
        case .regularExpression:
            TextField(L10n.text("正则表达式，例如 ^\\d{6}$"), text: rule.value)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity)
        case .contains, .startsWith, .endsWith:
            TextField(L10n.text("匹配内容"), text: rule.value)
                .frame(maxWidth: .infinity)
        }
    }

    private func defaultRule(
        _ kind: ClipboardClassificationRuleKind
    ) -> ClipboardClassificationRule {
        ClipboardClassificationRule(
            kind: kind,
            value: kind == .contentType ? ClipboardContentCategory.text.rawValue : ""
        )
    }
}

private struct PermissionStatusRow: View {
    let isTrusted: Bool
    let onRefresh: () -> Void
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(L10n.text(isTrusted ? "已允许自动粘贴" : "需要允许辅助功能权限"), systemImage: isTrusted ? "checkmark.circle" : "lock")
                .font(.caption)
                .foregroundStyle(isTrusted ? Color.secondary : Color.orange)
            Spacer()
            if isTrusted {
                Button(L10n.text("刷新"), action: onRefresh)
                    .font(.caption)
            } else {
                Button(L10n.text("去允许"), action: onRequest)
                    .font(.caption)
            }
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
        button.title = isRecording ? L10n.text("按下快捷键...") : HotKeyPolicy.label(hotKey)
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
