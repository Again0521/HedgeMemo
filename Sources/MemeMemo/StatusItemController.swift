import AppKit
import MemeMemoCore
import SwiftUI

/// Owns the menu bar status item. Left click opens the meme popover; right click
/// (or a control-click) opens the utilities menu holding import/export/screenshot/settings.
@MainActor
final class StatusItemController: NSObject {
    private let services: AppServices
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var settingsWindow = SettingsWindowController(
        clipboardStore: services.clipboardStore,
        screenshotSettingsStore: services.screenshotSettingsStore,
        hotKeyWarnings: { [services] in services.hotKeyWarnings }
    )

    init(services: AppServices) {
        self.services = services
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let icon = HedgehogIcon.statusImage
        icon.isTemplate = true
        button.image = icon
        button.imagePosition = .imageOnly
        button.toolTip = "MemeMemo"
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        // NSPopover already renders with native vibrancy chrome.
        popover.contentViewController = NSHostingController(rootView: MemePanelView(store: services.memeStore))
    }

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showMenu() {
        popover.performClose(nil)
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(actionItem("导入图片…", #selector(importImages)))
        menu.addItem(actionItem("导入压缩包…", #selector(importArchive)))
        menu.addItem(actionItem("导出全部…", #selector(exportArchive)))
        menu.addItem(.separator())

        let screenshot = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        let screenshotMenu = NSMenu()
        screenshotMenu.addItem(actionItem("按当前模式截图", #selector(screenshotDefault)))
        screenshotMenu.addItem(.separator())
        screenshotMenu.addItem(actionItem("手动框选", #selector(screenshotManual)))
        screenshotMenu.addItem(actionItem("智能窗口", #selector(screenshotSmart)))
        screenshot.submenu = screenshotMenu
        menu.addItem(screenshot)
        menu.addItem(.separator())

        menu.addItem(actionItem("设置…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 MemeMemo", #selector(quit)))
        return menu
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func importImages() { LibraryActions.importImages(into: services.memeStore) }
    @objc private func importArchive() { LibraryActions.importArchive(into: services.memeStore) }
    @objc private func exportArchive() { LibraryActions.exportArchive(from: services.memeStore) }
    @objc private func screenshotDefault() { services.captureScreenshot(requestedMode: nil) }
    @objc private func screenshotManual() { services.captureScreenshot(requestedMode: .manualSelection) }
    @objc private func screenshotSmart() { services.captureScreenshot(requestedMode: .smartWindow) }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
