import AppKit
import MemeMemoCore
import SwiftUI

@MainActor
final class MemeMemoAppDelegate: NSObject, NSApplicationDelegate {
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
        if let index = arguments.firstIndex(of: "--preview-screenshot"), arguments.indices.contains(index + 1) {
            let imageURL = URL(fileURLWithPath: arguments[index + 1])
            DispatchQueue.main.async { services.previewScreenshotEditor(imageURL: imageURL) }
        }
    }
}

@main
struct MemeMemoApp: App {
    @NSApplicationDelegateAdaptor(MemeMemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
