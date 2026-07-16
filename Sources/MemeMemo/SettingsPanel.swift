import AppKit
import MemeMemoCore
import SwiftUI

/// Hosts the settings UI in a standalone translucent panel, opened from the status bar menu.
@MainActor
final class SettingsWindowController: NSObject {
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
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.applyTranslucentChrome(cornerRadius: 12)

        let content = SettingsPanelView(
            clipboardStore: clipboardStore,
            screenshotSettingsStore: screenshotSettingsStore,
            hotKeyWarnings: hotKeyWarnings(),
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        hosting.frame = panel.contentView?.bounds ?? .zero
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}

struct SettingsPanelView: View {
    @ObservedObject var clipboardStore: ClipboardHistoryStore
    @ObservedObject var screenshotSettingsStore: ScreenshotSettingsStore
    let hotKeyWarnings: [String]
    let onClose: () -> Void
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    clipboardSection
                    screenshotSection
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
        .padding(20)
        .frame(width: 400, height: 520)
        .background(VisualEffectBackground())
        .onAppear { refreshAccessibilityTrust() }
    }

    private var clipboardSection: some View {
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
    }

    private var screenshotSection: some View {
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
