import AppKit
import Carbon.HIToolbox
import Combine
import ImageIO
import MemeMemoCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppServices: ObservableObject {
    let memeStore = MemeStore()
    let clipboardStore = ClipboardHistoryStore()
    let screenshotSettingsStore = ScreenshotSettingsStore()
    @Published private(set) var hotKeyWarnings: [String] = []

    private var hotKeyController: GlobalHotKeyController?
    private var clipboardPanelController: ClipboardHistoryPanelController?
    private let screenshotService = ScreenshotService()
    private let screenshotEditor = ScreenshotEditorPanelController()
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--preview-") }) {
            clipboardStore.startMonitoring()
        }

        let panelController = ClipboardHistoryPanelController(store: clipboardStore, memeStore: memeStore)
        let hotKey = GlobalHotKeyController()
        updateHotKeyWarning(.clipboard, status: hotKey.registerClipboardHotKey(clipboardStore.settings.hotKey ?? .defaultClipboard) {
            panelController.toggle()
        })
        updateHotKeyWarning(.screenshot, status: hotKey.registerScreenshotHotKey(screenshotSettingsStore.settings.hotKey ?? .defaultScreenshot) { [weak self] in
            self?.captureScreenshot()
        })
        clipboardStore.$settings
            .dropFirst()
            .map { $0.hotKey ?? .defaultClipboard }
            .removeDuplicates()
            .sink { [weak self, weak panelController, weak hotKey] definition in
                guard let self, let panelController else { return }
                let status = hotKey?.registerClipboardHotKey(definition) {
                    panelController.toggle()
                } ?? OSStatus(eventHotKeyInvalidErr)
                Task { @MainActor in self.updateHotKeyWarning(.clipboard, status: status) }
            }
            .store(in: &cancellables)
        screenshotSettingsStore.$settings
            .dropFirst()
            .map { $0.hotKey ?? .defaultScreenshot }
            .removeDuplicates()
            .sink { [weak self, weak hotKey] definition in
                let status = hotKey?.registerScreenshotHotKey(definition) { [weak self] in
                    self?.captureScreenshot()
                } ?? OSStatus(eventHotKeyInvalidErr)
                Task { @MainActor in self?.updateHotKeyWarning(.screenshot, status: status) }
            }
            .store(in: &cancellables)
        memeStore.$captureEnabled
            .removeDuplicates()
            .sink { [weak self] capturing in
                self?.clipboardStore.isRecordingPaused = capturing
            }
            .store(in: &cancellables)

        clipboardPanelController = panelController
        hotKeyController = hotKey
    }

    func captureScreenshot(requestedMode: ScreenshotMode? = nil) {
        let mode = ScreenshotPolicy.resolvedMode(settings: screenshotSettingsStore.settings, requestedMode: requestedMode)
        screenshotService.capture(mode: mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let image):
                self.handleCapturedScreenshot(image, mode: mode)
            case .failure(let error):
                self.memeStore.report(error)
            }
        }
    }

    func previewScreenshotEditor(imageURL: URL) {
        guard let image = NSImage(contentsOf: imageURL) else { return }
        screenshotEditor.edit(image: image) { [weak self] editedImage in
            guard let self, let editedImage else { return }
            self.copyScreenshot(editedImage)
        }
    }

    func previewClipboard(category: ClipboardContentCategory) {
        clipboardPanelController?.preview(category: category)
    }

    func previewClipboardStress() {
        clipboardPanelController?.previewStress()
    }

    /// Runs the clipboard panel layout/material self-check and terminates the
    /// process with a nonzero status on failure (used by --preview-verify-layout).
    func verifyClipboardLayout() {
        guard let clipboardPanelController else {
            print("LAYOUT SELF-CHECK FAILED\n  ✗ clipboard panel controller unavailable")
            exit(1)
        }
        clipboardPanelController.runLayoutSelfCheck { passed, summary in
            print(summary)
            exit(passed ? 0 : 1)
        }
    }

    private func handleCapturedScreenshot(_ image: NSImage, mode: ScreenshotMode) {
        screenshotSettingsStore.markCapture(mode: mode)
        guard screenshotSettingsStore.settings.opensEditorAfterCapture else {
            copyScreenshot(image)
            return
        }
        screenshotEditor.edit(image: image) { [weak self] editedImage in
            guard let self, let editedImage else { return }
            self.copyScreenshot(editedImage)
        }
    }

    /// "完成" means the screenshot is ready to paste. It does not add the
    /// screenshot to the meme library; that remains an explicit user action.
    private func copyScreenshot(_ image: NSImage) {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            memeStore.report(MemeRepositoryError.cannotEncodeImage)
            return
        }
        Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                ScreenshotPNGEncoder.data(for: cgImage)
            }.value
            guard let self, let data else {
                self?.memeStore.report(MemeRepositoryError.cannotEncodeImage)
                return
            }
            let payload = ImageAssetData(data: data, fileExtension: "png")
            guard payload.write(to: .general) else {
                memeStore.report(MemeRepositoryError.cannotEncodeImage)
                return
            }
        }
    }

    private func updateHotKeyWarning(_ kind: HotKeyKind, status: OSStatus) {
        let prefix = kind == .clipboard ? "剪贴板快捷键" : "截图快捷键"
        let message: String?
        if status == noErr {
            message = nil
        } else if status == OSStatus(eventHotKeyExistsErr) {
            message = "\(prefix) 已被占用，请换一个。"
        } else if status == OSStatus(eventHotKeyInvalidErr) {
            message = "\(prefix) 无效，请重新录制。"
        } else {
            message = "\(prefix) 注册失败，请换一个。"
        }
        hotKeyWarnings.removeAll { $0.hasPrefix(prefix) }
        if let message { hotKeyWarnings.append(message) }
    }
}

private enum ScreenshotPNGEncoder {
    static func data(for image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

final class GlobalHotKeyController: @unchecked Sendable {
    private var hotKeyRefs = [UInt32: EventHotKeyRef]()
    private var eventHandler: EventHandlerRef?
    private var actions = [UInt32: () -> Void]()
    private static let signature: OSType = 0x4d4d4348

    deinit {
        for hotKeyRef in hotKeyRefs.values { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func registerClipboardHotKey(_ hotKey: HotKeyDefinition, onTrigger: @escaping () -> Void) -> OSStatus {
        register(id: 1, hotKey: hotKey, onTrigger: onTrigger)
    }

    func registerScreenshotHotKey(_ hotKey: HotKeyDefinition, onTrigger: @escaping () -> Void) -> OSStatus {
        register(id: 2, hotKey: hotKey, onTrigger: onTrigger)
    }

    private func register(id: UInt32, hotKey: HotKeyDefinition, onTrigger: @escaping () -> Void) -> OSStatus {
        installHandlerIfNeeded()
        if let hotKeyRef = hotKeyRefs[id] {
            UnregisterEventHotKey(hotKeyRef)
            hotKeyRefs[id] = nil
        }
        guard hotKey.isUsable else {
            actions[id] = nil
            return OSStatus(eventHotKeyInvalidErr)
        }
        actions[id] = onTrigger
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return status }
        hotKeyRefs[id] = hotKeyRef
        return noErr
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotKeyController.signature else { return noErr }
                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in controller.actions[hotKeyID.id]?() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }
}

private enum HotKeyKind {
    case clipboard
    case screenshot
}

private extension HotKeyDefinition {
    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if command { modifiers |= UInt32(cmdKey) }
        if option { modifiers |= UInt32(optionKey) }
        if control { modifiers |= UInt32(controlKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
