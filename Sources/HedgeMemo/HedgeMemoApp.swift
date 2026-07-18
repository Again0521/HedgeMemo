import AppKit
import HedgeMemoCore
import SwiftUI

@MainActor
final class HedgeMemoAppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let services = AppServices()
        services.start()
        let statusItemController = StatusItemController(services: services)
        self.statusItemController = statusItemController
        self.services = services

        let arguments = CommandLine.arguments
        if arguments.contains("--preview-settings") {
            DispatchQueue.main.async { statusItemController.previewSettings() }
        }
        if arguments.contains("--preview-memes") {
            DispatchQueue.main.async { statusItemController.previewMemes() }
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
        if let index = arguments.firstIndex(of: "--preview-screenshot"), arguments.indices.contains(index + 1) {
            let imageURL = URL(fileURLWithPath: arguments[index + 1])
            DispatchQueue.main.async { services.previewScreenshotEditor(imageURL: imageURL) }
        }
    }
}

@main
struct HedgeMemoApp: App {
    @NSApplicationDelegateAdaptor(HedgeMemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
