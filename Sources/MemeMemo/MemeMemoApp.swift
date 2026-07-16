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
        statusItemController = StatusItemController(services: services)
        self.services = services
    }
}

@main
struct MemeMemoApp: App {
    @NSApplicationDelegateAdaptor(MemeMemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
