import AppKit
import HedgeMemoCore
import SwiftUI

/// Owns the menu bar status item. Left click opens the meme popover; right click
/// (or a control-click) opens the utilities menu holding import/export/screenshot/settings.
@MainActor
final class StatusItemController: NSObject {
    private let services: AppServices
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// Keep the menu alive until AppKit has finished its tracking loop. Clearing
    /// `statusItem.menu` immediately after `performClick` leaves a stale menu
    /// responder behind when an item opens a modal panel.
    private var activeMenu: NSMenu?
    /// Closes the popover on a click outside it. A transient popover would do
    /// this itself, but transient dismissal also fires the moment a drag leaves
    /// the popover bounds, which cancelled meme reordering mid-drag. So the
    /// popover is application-defined and dismissal is managed here instead.
    private var outsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
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
        button.toolTip = "HedgeMemo"
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
        clampPopoverToScreen()
        // AppKit may still adjust the popover frame right after `show`;
        // re-clamp once that settles so the final position is on screen too.
        DispatchQueue.main.async { [weak self] in self?.clampPopoverToScreen() }
        startOutsideClickMonitor()
    }

    /// A status item near the right screen edge can get its wide popover
    /// placed partially offscreen, cutting off the meme grid. Shift the whole
    /// popover window back inside the visible frame — never clip its content.
    private func clampPopoverToScreen() {
        guard popover.isShown,
              let window = popover.contentViewController?.view.window else { return }
        guard let screen = window.screen
            ?? statusItem.button?.window?.screen
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let inset: CGFloat = 8
        var frame = window.frame
        frame.origin.x = min(frame.origin.x, visible.maxX - frame.width - inset)
        frame.origin.x = max(frame.origin.x, visible.minX + inset)
        // Keep the bottom edge on screen as well; the top edge stays where the
        // system anchored it under the menu bar.
        frame.origin.y = max(frame.origin.y, visible.minY + inset)
        guard abs(frame.origin.x - window.frame.origin.x) > 0.5
            || abs(frame.origin.y - window.frame.origin.y) > 0.5 else { return }
        window.setFrame(frame, display: true)
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
        // Application-defined popovers do not get transient dismissal for
        // clicks in our own process. Add the corresponding local monitor, but
        // never close for the popover window or its category-editor sheet.
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.isInsidePopoverHierarchy(event) { return event }
            self.popover.performClose(nil)
            return event
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }

    private func isInsidePopoverHierarchy(_ event: NSEvent) -> Bool {
        guard let popoverWindow = popover.contentViewController?.view.window else { return false }
        guard let eventWindow = event.window else { return false }
        return eventWindow === popoverWindow || eventWindow.sheetParent === popoverWindow
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = buildMenu()
        menu.delegate = self
        activeMenu = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
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
        menu.addItem(actionItem("退出 HedgeMemo", #selector(quit)))
        return menu
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Let the menu tracking loop unwind before opening an app-modal file or
    /// selection panel. This prevents the next menu from becoming inert after
    /// the user closes import/export with the traffic-light button.
    @objc private func importArchive() {
        DispatchQueue.main.async { [services] in
            LibraryActions.importArchive(into: services.memeStore, clipboardStore: services.clipboardStore)
        }
    }
    @objc private func exportArchive() {
        DispatchQueue.main.async { [services] in
            LibraryActions.exportArchive(from: services.memeStore, clipboardStore: services.clipboardStore)
        }
    }
    @objc private func screenshotDefault() { services.captureScreenshot(requestedMode: nil) }
    @objc private func screenshotManual() { services.captureScreenshot(requestedMode: .manualSelection) }
    @objc private func screenshotSmart() { services.captureScreenshot(requestedMode: .smartWindow) }
    @objc private func openSettings() {
        DispatchQueue.main.async { [weak self] in self?.settingsWindow.show() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func previewSettings() { settingsWindow.show() }
    func previewMemes() { togglePopover() }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        // Dispatching one turn later avoids mutating the status item's menu
        // while AppKit is completing its own dismissal callback.
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self, let menu, self.activeMenu === menu else { return }
            self.statusItem.menu = nil
            self.activeMenu = nil
        }
    }
}
