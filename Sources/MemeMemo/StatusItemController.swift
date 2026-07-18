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
    /// Closes the popover on a click outside it. A transient popover would do
    /// this itself, but transient dismissal also fires the moment a drag leaves
    /// the popover bounds, which cancelled meme reordering mid-drag. So the
    /// popover is application-defined and dismissal is managed here instead.
    private var outsideClickMonitor: Any?
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
        // The hedgehog is a colored picture (dark body, white snout), not a
        // monochrome glyph — keep HedgehogIcon's isTemplate = false. Forcing a
        // template here flattened it into an all-dark silhouette with no face.
        let icon = HedgehogIcon.statusImage
        button.image = icon
        button.imagePosition = .imageOnly
        button.toolTip = "MemeMemo"
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        // Not `.transient`: transient dismissal fires as soon as a drag session
        // leaves the popover, which killed drag-to-reorder. Dismissal is handled
        // by the outside-click monitor started in `togglePopover`.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        // NSPopover already renders with native vibrancy chrome.
        popover.contentViewController = NSHostingController(rootView: MemePanelView(
            store: services.memeStore,
            onDismiss: { [weak self] in self?.popover.performClose(nil) }
        ))
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
        startOutsideClickMonitor()
    }

    /// Global monitors only see events dispatched to *other* applications, so a
    /// click inside the popover (our app) never triggers a close, but a click on
    /// the desktop or another app does. Clicks on our own status-item button go
    /// through `handleClick`, not this monitor.
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(actionItem("导入 ZIP…", #selector(importArchive)))
        menu.addItem(actionItem("导出 ZIP…", #selector(exportArchive)))
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

    @objc private func importArchive() { LibraryActions.importArchive(into: services.memeStore, clipboardStore: services.clipboardStore) }
    @objc private func exportArchive() { LibraryActions.exportArchive(from: services.memeStore, clipboardStore: services.clipboardStore) }
    @objc private func screenshotDefault() { services.captureScreenshot(requestedMode: nil) }
    @objc private func screenshotManual() { services.captureScreenshot(requestedMode: .manualSelection) }
    @objc private func screenshotSmart() { services.captureScreenshot(requestedMode: .smartWindow) }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    func previewSettings() { settingsWindow.show() }
    func previewMemes() { togglePopover() }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }
}
