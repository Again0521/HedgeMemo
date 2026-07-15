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
        MenuBarExtra("MemeMemo", systemImage: "face.smiling") {
            MemePanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
