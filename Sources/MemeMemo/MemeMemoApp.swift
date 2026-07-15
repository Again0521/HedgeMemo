import AppKit
import MemeMemoCore
import SwiftUI

final class MemeMemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MemeMemoApp: App {
    @NSApplicationDelegateAdaptor(MemeMemoAppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        MenuBarExtra {
            MemePanelView(
                store: services.memeStore,
                clipboardStore: services.clipboardStore,
                screenshotSettingsStore: services.screenshotSettingsStore,
                hotKeyWarnings: services.hotKeyWarnings,
                onScreenshot: services.captureScreenshot
            )
        } label: {
            Image(nsImage: HedgehogIcon.statusImage)
        }
        .menuBarExtraStyle(.window)
    }
}
