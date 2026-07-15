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
    @StateObject private var store = MemeStore()

    var body: some Scene {
        MenuBarExtra {
            MemePanelView(store: store)
        } label: {
            Image(nsImage: HedgehogIcon.statusImage)
        }
        .menuBarExtraStyle(.window)
    }
}
