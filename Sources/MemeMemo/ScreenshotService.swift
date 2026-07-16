import AppKit
import CoreGraphics
import Foundation
import MemeMemoCore

@MainActor
final class ScreenshotService: NSObject {
    enum ScreenshotError: LocalizedError {
        case screenRecordingNotAllowed
        case noWindowAtPointer
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .screenRecordingNotAllowed: "需要允许屏幕录制权限后才能截图。"
            case .noWindowAtPointer: "鼠标下方没有可截取的窗口。"
            case .captureFailed: "截图失败，请重试。"
            }
        }
    }

    private var selectionController: ManualScreenshotSelectionController?
    private var windowPickerController: SmartWindowPickerController?

    func capture(mode: ScreenshotMode, completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard Self.hasScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            completion(.failure(ScreenshotError.screenRecordingNotAllowed))
            return
        }

        switch mode {
        case .manualSelection:
            captureManualSelection(completion: completion)
        case .smartWindow:
            captureSmartWindow(completion: completion)
        }
    }

    private func captureManualSelection(completion: @escaping (Result<NSImage, Error>) -> Void) {
        let controller = ManualScreenshotSelectionController { [weak self] rect in
            guard let self else { return }
            self.selectionController = nil
            guard let rect, rect.width >= 4, rect.height >= 4 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if let image = Self.captureScreen(rect: rect) {
                    completion(.success(image))
                } else {
                    completion(.failure(ScreenshotError.captureFailed))
                }
            }
        }
        selectionController = controller
        controller.begin()
    }

    /// Interactive pick: an overlay follows the mouse and highlights the window
    /// underneath; clicking captures it, Esc cancels. This replaces the old
    /// point-in-time detection, which failed whenever the capture was triggered
    /// from the menu bar (the pointer was over the menu, never over a window).
    private func captureSmartWindow(completion: @escaping (Result<NSImage, Error>) -> Void) {
        let picker = SmartWindowPickerController(
            windowProvider: { Self.windowUnderPointer() },
            toViewSpace: { Self.quartzToAppKit($0) }
        ) { [weak self] window in
            self?.windowPickerController = nil
            guard let window else { return }
            // Let the overlay disappear before capturing so it never shows in the shot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.finishSmartWindowCapture(window: window, completion: completion)
            }
        }
        windowPickerController = picker
        picker.begin()
    }

    private func finishSmartWindowCapture(window: CapturableWindow, completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard let image = CGWindowListCreateImage(
            window.bounds,
            .optionIncludingWindow,
            window.id,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            completion(.failure(ScreenshotError.captureFailed))
            return
        }
        completion(.success(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))))
    }

    private static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func captureScreen(rect: CGRect) -> NSImage? {
        let quartzRect = appKitToQuartz(rect)
        guard let image = CGWindowListCreateImage(quartzRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func windowUnderPointer() -> CapturableWindow? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let point = appKitToQuartz(NSEvent.mouseLocation)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for windowInfo in info {
            guard let window = CapturableWindow(info: windowInfo),
                  window.ownerPID != ownPID,
                  window.layer == 0,
                  window.alpha > 0,
                  window.bounds.contains(point) else { continue }
            return window
        }
        return nil
    }

    private static func appKitToQuartz(_ rect: CGRect) -> CGRect {
        let union = screenUnion
        return CGRect(
            x: rect.minX,
            y: union.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func appKitToQuartz(_ point: NSPoint) -> CGPoint {
        let union = screenUnion
        return CGPoint(x: point.x, y: union.maxY - point.y)
    }

    private static func quartzToAppKit(_ rect: CGRect) -> CGRect {
        let union = screenUnion
        return CGRect(
            x: rect.minX,
            y: union.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static var screenUnion: CGRect {
        NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
    }
}

private struct CapturableWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    init?(info: [String: Any]) {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              let alpha = info[kCGWindowAlpha as String] as? Double,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
        self.id = id
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

@MainActor
private final class SmartWindowPickerController {
    private let windowProvider: () -> CapturableWindow?
    private let toViewSpace: (CGRect) -> CGRect
    private let onComplete: (CapturableWindow?) -> Void
    private var overlay: NSWindow?

    init(
        windowProvider: @escaping () -> CapturableWindow?,
        toViewSpace: @escaping (CGRect) -> CGRect,
        onComplete: @escaping (CapturableWindow?) -> Void
    ) {
        self.windowProvider = windowProvider
        self.toViewSpace = toViewSpace
        self.onComplete = onComplete
    }

    func begin() {
        let frame = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let overlay = ScreenshotOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = SmartWindowPickerView(
            frame: NSRect(origin: .zero, size: frame.size),
            windowProvider: windowProvider,
            highlightRect: { [toViewSpace] bounds in
                let global = toViewSpace(bounds)
                return CGRect(
                    x: global.minX - frame.minX,
                    y: global.minY - frame.minY,
                    width: global.width,
                    height: global.height
                )
            },
            onComplete: { [weak self] window in self?.finish(window: window) }
        )
        overlay.contentView = view
        overlay.setFrame(frame, display: true)
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.overlay = overlay
    }

    private func finish(window: CapturableWindow?) {
        overlay?.orderOut(nil)
        overlay = nil
        onComplete(window)
    }
}

private final class SmartWindowPickerView: NSView {
    private let windowProvider: () -> CapturableWindow?
    private let highlightRect: (CGRect) -> CGRect
    private let onComplete: (CapturableWindow?) -> Void
    private var target: CapturableWindow?

    init(
        frame frameRect: NSRect,
        windowProvider: @escaping () -> CapturableWindow?,
        highlightRect: @escaping (CGRect) -> CGRect,
        onComplete: @escaping (CapturableWindow?) -> Void
    ) {
        self.windowProvider = windowProvider
        self.highlightRect = highlightRect
        self.onComplete = onComplete
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        refreshTarget()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        refreshTarget()
    }

    override func mouseDown(with event: NSEvent) {
        onComplete(target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onComplete(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func refreshTarget() {
        target = windowProvider()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dimmingPath = NSBezierPath(rect: bounds)
        let selection = target.map { highlightRect($0.bounds) }
        if let selection {
            dimmingPath.append(NSBezierPath(rect: selection))
        }
        dimmingPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.22).setFill()
        dimmingPath.fill()

        guard let selection else { return }
        let border = NSBezierPath(roundedRect: selection.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.setStroke()
        border.lineWidth = 3
        border.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor
private final class ManualScreenshotSelectionController {
    private let onComplete: (CGRect?) -> Void
    private var window: NSWindow?

    init(onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
    }

    func begin() {
        let frame = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let window = ScreenshotOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ScreenshotSelectionView(frame: NSRect(origin: .zero, size: frame.size)) { [weak self] rect in
            self?.finish(rect: rect)
        }
        window.contentView = view
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func finish(rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        onComplete(rect)
    }
}

private final class ScreenshotOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        backgroundColor = .clear
        isOpaque = false
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hasShadow = false
    }
}

private final class ScreenshotSelectionView: NSView {
    private let onComplete: (CGRect?) -> Void
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    init(frame frameRect: NSRect, onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dimmingPath = NSBezierPath(rect: bounds)
        if let selection = selectionRect {
            dimmingPath.append(NSBezierPath(rect: selection))
        }
        dimmingPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.28).setFill()
        dimmingPath.fill()

        guard let selection = selectionRect else { return }
        let borderPath = NSBezierPath(roundedRect: selection, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.setStroke()
        borderPath.lineWidth = 2
        borderPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let localRect = selectionRect, let window else {
            onComplete(nil)
            return
        }
        let globalRect = NSRect(
            x: window.frame.minX + localRect.minX,
            y: window.frame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        onComplete(globalRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onComplete(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }
}
