import AppKit
import HedgeMemoCore
import SwiftUI

@MainActor
final class HedgeMemoAppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var statusItemController: StatusItemController?
    private var textCompletionCrashGuard: TextCompletionCrashGuard?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLanguage.bootstrap()
        NSApp.setActivationPolicy(.accessory)
        // Install before any SwiftUI/AppKit input is created. macOS 27 can
        // otherwise retain its completion remote view until the next display
        // wake and abort while reconnecting the menu-bar status item.
        textCompletionCrashGuard = TextCompletionCrashGuard()
        let services = AppServices()
        services.start()
        let statusItemController = StatusItemController(services: services)
        self.statusItemController = statusItemController
        self.services = services

        let arguments = CommandLine.arguments
        if arguments.contains("--preview-settings") {
            DispatchQueue.main.async { statusItemController.previewSettings() }
        }
        if arguments.contains("--preview-popup") {
            // Let application launch finish before entering the modal event
            // loop; otherwise `open --args --preview-popup` waits for the app's
            // ready handshake instead of returning to the preview harness.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UnifiedPopupPanel.requestText(
                    title: L10n.text("新建分类"),
                    message: L10n.text("输入分类名称后按 Return 保存。"),
                    placeholder: L10n.text("分类名称"),
                    confirmationTitle: L10n.text("保存")
                ) { _ in }
            }
        }
        if arguments.contains("--preview-memes") {
            // Status-item popovers also need LaunchServices' ready handshake to
            // finish before they enter their own event tracking loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                statusItemController.previewMemes()
            }
        }
        if arguments.contains("--preview-clipboard-code") {
            DispatchQueue.main.async { services.previewClipboard(category: .code) }
        }
        if arguments.contains("--preview-verify-layout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { services.verifyClipboardLayout() }
        }
        if arguments.contains("--preview-clipboard-stress") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { services.previewClipboardStress() }
        }
        if arguments.contains("--preview-clipboard-lifecycle-stress") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                services.previewClipboardLifecycleStress()
            }
        }
        if arguments.contains("--preview-clipboard-advanced") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                services.previewClipboardAdvancedMode()
            }
        }
        if let index = arguments.firstIndex(of: "--preview-screenshot"), arguments.indices.contains(index + 1) {
            let imageURL = URL(fileURLWithPath: arguments[index + 1])
            DispatchQueue.main.async { services.previewScreenshotEditor(imageURL: imageURL) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.stopTransientMemoryManagement()
        services?.clipboardStore.flushPendingSave()
        services?.memeStore.flushPendingSave()
    }
}

@main
struct HedgeMemoApp: App {
    @NSApplicationDelegateAdaptor(HedgeMemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
