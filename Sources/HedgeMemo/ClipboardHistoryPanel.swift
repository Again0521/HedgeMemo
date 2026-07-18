import AppKit
import HedgeMemoCore
import SwiftUI

/// The slideout is presentation state owned by the one Maccy-style
/// FloatingPanel.  Keeping it in the same hosting hierarchy is intentional:
/// one native glass view samples the desktop once for both list and preview.
@MainActor
private final class ClipboardDetailPresentation: ObservableObject {
    enum Placement: Equatable {
        case left
        case right
        case overlay
    }

    /// Every preview geometry value is published as one snapshot.  Publishing
    /// the entry, offsets and size one property at a time let SwiftUI draw
    /// transient combinations (for example, a tall card with a short-card
    /// offset) while a pointer moved between rows.  That was the direct cause
    /// of the clipboard card flashing or appearing to jump.
    struct State {
        let entry: ClipboardEntry?
        let imageURL: URL?
        let cardSize: NSSize
        /// The transparent sideout lane is deliberately wider than a compact
        /// text card when there is room.  Its frame remains stable while the
        /// actual preview card changes between short text and long code.
        let sideSlotWidth: CGFloat
        let placement: Placement
        let mainTopOffset: CGFloat
        let mainHeight: CGFloat
        let detailTopOffset: CGFloat

        static let hidden = State(
            entry: nil,
            imageURL: nil,
            cardSize: .zero,
            sideSlotWidth: 0,
            placement: .right,
            mainTopOffset: 0,
            mainHeight: 0,
            detailTopOffset: 0
        )
    }

    @Published private(set) var state = State.hidden

    var entry: ClipboardEntry? { state.entry }
    var imageURL: URL? { state.imageURL }
    var cardSize: NSSize { state.cardSize }
    var sideSlotWidth: CGFloat { state.sideSlotWidth }
    var placement: Placement { state.placement }
    var mainTopOffset: CGFloat { state.mainTopOffset }
    var mainHeight: CGFloat { state.mainHeight }
    var detailTopOffset: CGFloat { state.detailTopOffset }
    var isVisible: Bool { state.entry != nil }

    func show(
        entry: ClipboardEntry,
        imageURL: URL?,
        cardSize: NSSize,
        sideSlotWidth: CGFloat,
        placement: Placement,
        mainTopOffset: CGFloat,
        mainHeight: CGFloat,
        detailTopOffset: CGFloat
    ) {
        state = State(
            entry: entry,
            imageURL: imageURL,
            cardSize: cardSize,
            sideSlotWidth: sideSlotWidth,
            placement: placement,
            mainTopOffset: mainTopOffset,
            mainHeight: mainHeight,
            detailTopOffset: detailTopOffset
        )
    }

    func hide() {
        state = .hidden
    }
}

/// Owns the dwell timer outside SwiftUI's value-type render lifecycle.  A
/// `DispatchWorkItem` captured by a View can retain a stale `@State` snapshot
/// after a list refresh, which made a valid one-second hover occasionally do
/// nothing.  This object keeps the current entry identity authoritative.
@MainActor
private final class ClipboardHoverPreviewDelay {
    private var openWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
    /// This is intentionally independent of SwiftUI's transient row views.
    /// A preview expansion can rebuild a row under a stationary pointer.
    private var hoveredEntryID: UUID?

    func schedule(entry: ClipboardEntry, fire: @escaping () -> Void) {
        let entryID = entry.id
        exitWork?.cancel()
        exitWork = nil
        // A replacement tracking area for the same visible row must not
        // restart the dwell timer or close an already-open preview.
        if hoveredEntryID == entryID { return }
        openWork?.cancel()
        hoveredEntryID = entryID
        let work = DispatchWorkItem { [weak self] in
            guard self?.hoveredEntryID == entryID else { return }
            self?.openWork = nil
            fire()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Give AppKit a short hand-off interval when a hovered row is rehosted.
    /// Expanding the single panel for its preview can cause AppKit to emit one
    /// synthetic exit before the replacement tracking area has its final
    /// frame.  The previous next-run-loop delay was too short: it cancelled a
    /// valid one-second hover before the preview could appear.  Eighty
    /// milliseconds remains visually immediate for a real exit, but lets the
    /// successor tracking area cancel this stale close reliably.
    func scheduleExit(entry: ClipboardEntry, fire: @escaping () -> Void) {
        let entryID = entry.id
        guard hoveredEntryID == entryID else { return }
        openWork?.cancel()
        openWork = nil
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.hoveredEntryID == entryID else { return }
            self?.hoveredEntryID = nil
            self?.exitWork = nil
            fire()
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func cancel() {
        openWork?.cancel()
        exitWork?.cancel()
        openWork = nil
        exitWork = nil
        hoveredEntryID = nil
    }
}

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardHistoryStore
    private let memeStore: MemeStore
    private let pinnedWindows: PinnedClipboardWindowsController
    private var panel: NSPanel?
    private var mainSurface: NSView?
    private var detailEntryID: UUID?
    private var clickOutsideMonitor: Any?
    private var localClickOutsideMonitor: Any?
    /// The main list's rect in screen coordinates — the single source of truth.
    /// It remains unchanged for the entire detail-preview lifecycle.
    private var mainScreenFrame: NSRect = .zero
    private let detailPresentation = ClipboardDetailPresentation()
    private let panelInset: CGFloat = 18
    /// A programmatic expansion is not a user drag.  NSPanel emits
    /// `windowDidMove` for both, so remember the expected frame and never use
    /// that notification to replace the list's anchor.
    private var pendingProgrammaticFrame: NSRect?

    init(store: ClipboardHistoryStore, memeStore: MemeStore) {
        self.store = store
        self.memeStore = memeStore
        pinnedWindows = PinnedClipboardWindowsController(store: store)
    }

    func toggle() {
        if panel?.isVisible == true { hide() }
        else { show() }
    }

    func preview(category: ClipboardContentCategory) {
        store.settings.activeCategoryKey = .builtin(category)
        show()
    }

    func hide() {
        hideDetail()
        stopClickOutsideMonitor()
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let content = ClipboardHistoryPanelView(
            store: store,
            detailPresentation: detailPresentation,
            onDone: { [weak self] in self?.hide() },
            onContentChange: { [weak self] contentHeight in
                self?.requestMainResize(contentHeight: contentHeight)
            },
            onDetailEntry: { [weak self] entry in
                DispatchQueue.main.async { self?.updateDetail(entry: entry) }
            },
            onAddToMemes: { [weak self] entry in
                self?.addToMemes(entry)
            },
            onTogglePin: { [weak self] entry in
                // Desktop pinning is a completed clipboard action: leave the
                // newly created note visible, but close the transient history
                // panel immediately.
                self?.pinnedWindows.toggle(entry)
                self?.hide()
            }
        )
        if let mainSurface {
            // Maccy's slideout uses one key FloatingPanel but two independently
            // sized glass shapes inside it.  Do not paint the entire union as
            // one oversized card: the list and preview must keep their own
            // heights while their native glass effects share this window's
            // active appearance.
            PanelMaterialHost.replace(content, in: mainSurface, usesWindowMaterial: false)
        }
        let key = store.settings.activeCategoryKey
        resize(
            contentHeight: ClipboardPanelLayout.contentHeight(for: store.orderedEntries(key: key), key: key),
            animate: false
        )
        position(panel)
        // Match the reference popup's activation contract. The material is
        // fixed by PanelMaterialHost; becoming key must not replace it with a
        // second focus/hover surface.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        startClickOutsideMonitor()
    }

    private func addToMemes(_ entry: ClipboardEntry) {
        guard let url = store.imageURL(for: entry), let payload = ImageAssetData(fileURL: url) else { return }
        _ = memeStore.addImageData(payload, note: entry.text)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: ClipboardPanelLayout.panelWidth, height: 420),
            // Match Maccy's floating window contract.  A borderless panel
            // drives NSGlassEffectView through a different auxiliary-window
            // compositor path on macOS 26 and is what produced the opaque
            // gray hover state.  The title bar remains completely hidden.
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Same as Maccy's FloatingPanel: transient geometry changes must not
        // interpolate a native window shadow through an intermediate rectangle.
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        // The clipboard is a non-activating panel.  Request pointer movement
        // explicitly so AppKit tracking areas continue to receive events when
        // another app remains key underneath it.
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        PanelMaterialHost.install(
            EmptyView(),
            in: panel,
            cornerRadius: 12,
            usesWindowMaterial: false
        )
        panel.hasShadow = true
        mainSurface = panel.contentView

        return panel
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedPanel = notification.object as? NSPanel, movedPanel === panel else { return }
        // `setFrame` for a preview expansion also produces this delegate
        // callback.  Only a real window drag is allowed to change the anchor
        // used to restore the standalone clipboard card.
        guard NSEvent.pressedMouseButtons != 0 else { return }
        if let expected = pendingProgrammaticFrame,
           framesMatch(movedPanel.frame, expected) {
            pendingProgrammaticFrame = nil
            return
        }
        if detailPresentation.isVisible {
            let gap: CGFloat = 10
            let sideOffset = detailPresentation.placement == .left
                ? detailPresentation.cardSize.width + gap
                : 0
            let mainY = movedPanel.frame.maxY
                - detailPresentation.mainTopOffset
                - detailPresentation.mainHeight
            mainScreenFrame = NSRect(
                x: movedPanel.frame.minX + sideOffset,
                y: mainY,
                width: ClipboardPanelLayout.panelWidth,
                height: detailPresentation.mainHeight
            )
        } else {
            mainScreenFrame = movedPanel.frame
        }
    }

    private func setPanelFrame(_ frame: NSRect, display: Bool = true) {
        guard let panel else { return }
        pendingProgrammaticFrame = frame
        panel.setFrame(frame, display: display, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        // AppKit normally delivers `windowDidMove` synchronously.  Clear an
        // unmatched pending value on the next run-loop turn so a later user
        // drag is never mistaken for this resize.
        DispatchQueue.main.async { [weak self] in
            self?.pendingProgrammaticFrame = nil
        }
    }

    private func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    /// The screen the panel lives on, falling back to wherever the mouse is.
    private var activeScreen: NSScreen? {
        if let screen = panel?.screen { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    /// Only the main card changes size, anchored by its top edge so the list
    /// never jumps under the pointer. The preview is temporarily hidden before
    /// sizing, then can be added back as a sibling card in the same window.
    private func resize(contentHeight: CGFloat, animate _: Bool) {
        guard let panel else { return }
        let visibleFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let height = ClipboardPanelLayout.panelHeight(
            contentHeight: contentHeight,
            availableHeight: visibleFrame.height - panelInset * 2
        )
        let currentMainFrame = mainScreenFrame.isEmpty ? panel.frame : mainScreenFrame
        var frame = currentMainFrame
        frame.size.width = ClipboardPanelLayout.panelWidth
        frame.size.height = height
        // Keep the top edge where it was when possible. Clamp both screen edges
        // after every category/query resize: dense image results can be much
        // taller than a short text category, and a one-sided clamp can hide the
        // search field above the menu bar after that switch.
        frame.origin.y = ClipboardPanelLayout.constrainedOriginY(
            preferredTop: currentMainFrame.maxY,
            height: height,
            visibleMinY: visibleFrame.minY,
            visibleMaxY: visibleFrame.maxY,
            inset: panelInset
        )
        if detailPresentation.isVisible,
           abs(frame.width - currentMainFrame.width) < 0.5,
           abs(frame.height - currentMainFrame.height) < 0.5,
           abs(frame.minY - currentMainFrame.minY) < 0.5 {
            return
        }
        hideDetail()
        // Native NSWindow frame animation and a hosted NSGlassEffectView do
        // not share one layout transaction.  Rendering the interpolated frame
        // was the source of the occasional compressed, horizontal-strip panel.
        // The SwiftUI content change is already animated where appropriate;
        // commit the host geometry atomically instead.
        setPanelFrame(frame)
        mainScreenFrame = frame
    }

    private func requestMainResize(contentHeight: CGFloat) {
        guard panel != nil else { return }
        if detailPresentation.isVisible { return }
        resize(contentHeight: contentHeight, animate: true)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let size = panel.frame.size
        let inset = panelInset
        let origin = NSPoint(
            x: min(max(mouse.x - size.width / 2, visibleFrame.minX + inset), visibleFrame.maxX - size.width - inset),
            y: min(max(mouse.y - 24 - size.height, visibleFrame.minY + inset), visibleFrame.maxY - size.height - inset)
        )
        panel.setFrameOrigin(origin)
        mainScreenFrame = panel.frame
    }

    // MARK: - Detail slideout

    /// Maccy's SlideoutView equivalent: expand the existing FloatingPanel and
    /// keep the clipboard card at its saved screen rect inside that union.
    private func updateDetail(entry: ClipboardEntry?) {
        guard let entry, let panel, panel.isVisible else {
            hideDetail()
            return
        }
        if detailEntryID == entry.id { return }
        detailEntryID = entry.id

        let visibleFrame = activeScreen?.visibleFrame ?? panel.frame
        let imageURL = store.imageURL(for: entry)
        let mainFrame = mainScreenFrame.isEmpty ? panel.frame : mainScreenFrame
        let inset = panelInset
        let cardGap: CGFloat = 10
        let leftAvailable = max(0, mainFrame.minX - visibleFrame.minX - inset - cardGap)
        let rightAvailable = max(0, visibleFrame.maxX - mainFrame.maxX - inset - cardGap)
        // Follow Maccy's placement rule: grow toward the preferred side, then
        // flip before the host would cross the visible screen.  The selected
        // side's actual width is passed into the layout calculation so an
        // edge invocation never creates an over-wide preview and shifts the
        // main list away from the pointer.
        let preferredSide: ClipboardDetailPresentation.Placement = leftAvailable >= rightAvailable ? .left : .right
        let preferredAvailable = preferredSide == .left ? leftAvailable : rightAvailable
        let canUseSide = preferredAvailable >= ClipboardDetailLayout.minimumSideWidth
        let placement: ClipboardDetailPresentation.Placement = canUseSide ? preferredSide : .overlay
        let previewAvailableWidth = placement == .overlay
            ? max(1, mainFrame.width - panelInset * 2)
            : preferredAvailable
        // Reserve a fixed sideout lane for the entire hover session. The card
        // itself stays content-sized inside this transparent lane, but a short
        // → long switch never needs to resize/reposition the FloatingPanel.
        // This preserves both Maccy's variable-height slideout and a stable
        // clipboard body.
        let sideSlotWidth = placement == .overlay
            ? mainFrame.width
            : ClipboardDetailLayout.hostSlotWidth(availableWidth: previewAvailableWidth)
        let previewHeightBudget = visibleFrame.height - panelInset * 2
        let size = ClipboardDetailLayout.cardSize(
            for: entry,
            imageURL: imageURL,
            availableHeight: previewHeightBudget,
            availableWidth: sideSlotWidth
        )
        let mouseY = NSEvent.mouseLocation.y
        let verticalHostMinY = visibleFrame.minY + panelInset
        let verticalHostMaxY = visibleFrame.maxY - panelInset
        // The actual card is content-sized and follows the hovered row, while
        // the host has already reserved the complete visible vertical lane.
        // Long code/text therefore gets its full allowed preview height
        // without moving the list when a previous row had a short card.
        let detailY = min(
            max(mouseY - size.height / 2, verticalHostMinY),
            verticalHostMaxY - size.height
        )
        let hostFrame: NSRect
        switch placement {
        case .left:
            hostFrame = NSRect(
                x: mainFrame.minX - sideSlotWidth - cardGap,
                y: verticalHostMinY,
                width: mainFrame.width + sideSlotWidth + cardGap,
                height: verticalHostMaxY - verticalHostMinY
            )
        case .right:
            hostFrame = NSRect(
                x: mainFrame.minX,
                y: verticalHostMinY,
                width: mainFrame.width + sideSlotWidth + cardGap,
                height: verticalHostMaxY - verticalHostMinY
            )
        case .overlay:
            hostFrame = mainFrame
        }
        detailPresentation.show(
            entry: entry,
            imageURL: imageURL,
            cardSize: size,
            sideSlotWidth: sideSlotWidth,
            placement: placement,
            mainTopOffset: hostFrame.maxY - mainFrame.maxY,
            mainHeight: mainFrame.height,
            detailTopOffset: placement == .overlay
                ? max(0, min(mainFrame.height - size.height, detailY - mainFrame.minY))
                : hostFrame.maxY - detailY - size.height
        )
        mainScreenFrame = mainFrame
        // Commit the SwiftUI presentation state and the AppKit host frame in
        // the *same* run-loop turn so they land in one CoreAnimation commit.
        // The previous next-turn dispatch let a full frame render with the
        // expanded offsets inside the not-yet-expanded window, which showed as
        // an occasional flash/jump the moment a preview appeared.  For
        // ordinary text hovers the host frame is unchanged; framesMatch still
        // skips the no-op commit that would force a full NSGlassEffectView
        // redraw (itself perceived as a flash).
        if !framesMatch(panel.frame, hostFrame) {
            setPanelFrame(hostFrame)
        }
    }

    private func hideDetail() {
        detailEntryID = nil
        detailPresentation.hide()
        guard panel != nil, !mainScreenFrame.isEmpty else { return }
        setPanelFrame(mainScreenFrame)
    }

    // MARK: - Click-outside dismissal

    /// A nonactivating panel does not reliably resign key when the user clicks
    /// another app or the desktop, so watch global clicks and close on any that
    /// land outside our windows.
    private func startClickOutsideMonitor() {
        guard clickOutsideMonitor == nil,
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--preview-") }) else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        // Global monitors deliberately do not receive clicks in this app. A
        // matching local monitor closes the nonactivating clipboard when the
        // user clicks another HedgeMemo/Codex window, while preserving every
        // click that lands inside the panel itself.
        localClickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.isInsideClipboardPanel(event) { return event }
            self.hide()
            return event
        }
    }

    private func stopClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        if let localClickOutsideMonitor {
            NSEvent.removeMonitor(localClickOutsideMonitor)
            self.localClickOutsideMonitor = nil
        }
    }

    private func isInsideClipboardPanel(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        if event.window === panel { return true }
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        return panel.frame.contains(screenPoint)
    }

    // MARK: - Visual stress preview (--preview-clipboard-stress)

    /// Replays the reported user flow for screenshot inspection: dense fake
    /// data, panel opened at the bottom of the screen, then a category switch
    /// through the real SwiftUI onChange → onContentChange → resize chain,
    /// then the hover detail card. The panel stays open (preview mode).
    func previewStress() {
        var fakes: [ClipboardEntry] = (1...40).map {
            ClipboardEntry(
                kind: .text,
                text: $0 == 20
                    ? Array(repeating: "很长的第二十条压力测试内容，用来把详情卡撑得比第一张高很多。", count: 12).joined(separator: "\n")
                    : "压力测试条目 \($0)",
                contentHash: "stress-\($0)"
            )
        }
        fakes.append(ClipboardEntry(kind: .text, text: "let a = 1;\nlet b = 2;", contentHash: "stress-code"))
        store.injectPreviewEntries(fakes)

        store.settings.activeCategoryKey = .builtin(.image)
        show()
        if let panel, let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 12))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            // The real user action: switching the category chip.
            self?.store.settings.activeCategoryKey = .builtin(.text)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            if let first = self.store.orderedEntries(key: .builtin(.text)).first {
                self.updateDetail(entry: first)
            }
        }
        // Hover a different entry with a much larger card: the main list's
        // screen position must not move by a single point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            let entries = self.store.orderedEntries(key: .builtin(.text))
            if entries.count > 20 { self.updateDetail(entry: entries[20]) }
        }
    }

    // MARK: - Layout self-check (--preview-verify-layout)

    /// Reproduces the reported failure end-to-end: open the panel at the very
    /// bottom of the screen, grow it to maximum height (dense category), and
    /// hover a detail card. Then assert that every window is fully on screen,
    /// the SwiftUI content is frame-locked to its window (no top clipping),
    /// and preview geometry never mutates the clipboard's own window frame.
    func runLayoutSelfCheck(completion: @escaping (Bool, String) -> Void) {
        show()
        guard let panel, let screen = panel.screen ?? NSScreen.main else {
            completion(false, "self-check: panel or screen missing")
            return
        }
        let visible = screen.visibleFrame
        // Bottom-right edge: this is the regression case.  The preview must
        // flip to the left and keep the list exactly under the pointer.
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - panelInset,
            y: visible.minY + 12
        ))
        mainScreenFrame = panel.frame
        // Force maximum growth, exactly what switching to a dense category does.
        resize(contentHeight: 10_000, animate: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let mainBeforeHovers = self.mainScreenFrame
            // Hover two entries with very different card sizes.
            self.updateDetail(entry: ClipboardEntry(kind: .text, text: "自检条目", contentHash: "self-check-small"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let hostAfterShortPreview = self.panel?.frame ?? .zero
                self.updateDetail(entry: ClipboardEntry(
                    kind: .text,
                    text: Array(repeating: "自检长内容行", count: 30).joined(separator: "\n"),
                    contentHash: "self-check-large"
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.evaluateSelfCheck(
                        visible: visible,
                        mainBeforeHovers: mainBeforeHovers,
                        hostAfterShortPreview: hostAfterShortPreview,
                        completion: completion
                    )
                }
            }
        }
    }

    private func evaluateSelfCheck(
        visible: NSRect,
        mainBeforeHovers: NSRect,
        hostAfterShortPreview: NSRect,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard let panel else {
            completion(false, "self-check: panel disappeared")
            return
        }
        var failures = [String]()
        var report = [String]()

        let frame = panel.frame
        report.append("visible=\(visible) window=\(frame) main=\(mainScreenFrame)")
        if frame.minY < visible.minY - 1 || frame.maxY > visible.maxY + 1 {
            failures.append("window frame leaves the visible screen vertically")
        }
        if mainScreenFrame.minY < visible.minY - 1 || mainScreenFrame.maxY > visible.maxY + 1 {
            failures.append("main list leaves the visible screen vertically")
        }
        // The core regression: hovering different entries must never move the list.
        if abs(mainScreenFrame.minX - mainBeforeHovers.minX) > 0.5
            || abs(mainScreenFrame.minY - mainBeforeHovers.minY) > 0.5
            || abs(mainScreenFrame.width - mainBeforeHovers.width) > 0.5
            || abs(mainScreenFrame.height - mainBeforeHovers.height) > 0.5 {
            failures.append("main list moved while hovering (\(mainBeforeHovers) -> \(mainScreenFrame))")
        }
        // This is the actual short → long regression: after the slideout is
        // open, a taller card must not issue a second host-window resize. A
        // changing transparent host frame is still perceptible as a flash
        // because AppKit redraws the NSGlassEffectView during that resize.
        if !framesMatch(frame, hostAfterShortPreview) {
            failures.append("host frame changed between short and long preview (\(hostAfterShortPreview) -> \(frame))")
        }

        let mainBounds = mainSurface?.bounds ?? .zero
        report.append("singleHostBounds=\(mainBounds)")
        if detailPresentation.isVisible {
            report.append("detail=single-host \(detailPresentation.cardSize)")
            if panel.frame.minY < visible.minY - 1 || panel.frame.maxY > visible.maxY + 1 {
                failures.append("single-host detail leaves the visible screen vertically")
            }
        } else {
            failures.append("detail card did not show")
        }
        if mainSurface == nil { failures.append("material root is missing") }

        hide()
        let passed = failures.isEmpty
        let summary = (passed ? "LAYOUT SELF-CHECK PASSED" : "LAYOUT SELF-CHECK FAILED")
            + (failures.isEmpty ? "" : "\n" + failures.map { "  ✗ \($0)" }.joined(separator: "\n"))
            + "\n" + report.map { "  · \($0)" }.joined(separator: "\n")
        completion(passed, summary)
    }
}

/// Borderless panels refuse key status by default; the search field needs it.
private final class KeyableClipboardPanel: NSPanel {
    // Match a native floating clipboard panel: keyboard navigation and search
    // remain available, while PanelMaterialHost keeps the visual material fixed.
    override var canBecomeKey: Bool { true }
}

// MARK: - Detail card content

private struct ClipboardDetailCard: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let cardSize: NSSize
    let codeHighlightTheme: CodeHighlightTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                sourceRow
                detailRow("类型", entry.contentCategory.displayName)
                detailRow("收录时间", entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("上次使用", entry.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "还未使用")
                detailRow("使用次数", "\(entry.useCount ?? 0) 次")
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("按 ⏎ 复制。按 ⌫ 删除。")
                Text(entry.isPinned ? "按 ⌘P 取消置顶。" : "按 ⌘P 置顶。")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var preview: some View {
        if entry.kind == .image, let imageURL {
            AnimatedImageFileView(url: imageURL)
                .frame(maxWidth: .infinity)
                .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if entry.contentCategory == .code {
            ScrollView(.vertical) {
                Text(CodeHighlighter.highlight(entry.text ?? "", theme: codeHighlightTheme))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    // The layout gives code a wider card first. Only a line
                    // that genuinely exceeds the available side wraps.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
        } else {
            ScrollView(.vertical) {
                Text(entry.text ?? entry.previewText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
    }

    private var sourceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("来源")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            SourceApplicationLabel(name: entry.sourceApp)
        }
        .font(.system(size: 11))
    }
}

/// Source names are persisted as text, not bundle identifiers. Resolve a
/// miniature icon only when the named app is presently running or can be found
/// in one of macOS's standard application locations. A failed lookup leaves
/// no placeholder, which avoids pretending an unknown app has an icon.
private struct SourceApplicationLabel: View {
    let name: String?

    var body: some View {
        HStack(spacing: 4) {
            if let image = SourceApplicationIcon.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
            }
            Text(name ?? "未知")
                .multilineTextAlignment(.trailing)
        }
    }
}

private enum SourceApplicationIcon {
    static func image(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let bundleURL = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        let fileManager = FileManager.default
        let candidates = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/\(name).app")
        ]
        guard let appPath = candidates.first(where: { fileManager.fileExists(atPath: $0) }) else { return nil }
        return NSWorkspace.shared.icon(forFile: appPath)
    }
}

private enum ClipboardDetailLayout {
    /// Maccy's minimum slideout width is 200 pt. Keep the same lower bound so
    /// a preview can still be shown beside a panel parked at a display edge.
    static let minimumSideWidth: CGFloat = 200
    private static let minimumWidth: CGFloat = minimumSideWidth
    private static let maximumWidth: CGFloat = 720
    /// Non-code previews are deliberately readable rather than a single wide
    /// line: roughly thirty Chinese glyphs per row at the preview font size.
    private static let readableTextCharactersPerLine = 30
    private static let horizontalPadding: CGFloat = 12
    // Includes the two dividers, metadata and instruction rows plus the card
    // padding. The previous undercount clipped the final rendered glyph line
    // below the bottom divider on CJK/code previews.
    private static let verticalChrome: CGFloat = 177
    // A single text line should not reserve a tall preview; only images get a
    // comfortable minimum so a thumbnail isn't cramped.
    private static let minimumPreviewHeight: CGFloat = 18
    private static let minimumImagePreviewHeight: CGFloat = 96
    private static let screenMargin: CGFloat = 24
    /// TextKit's glyph bounds can exceed a font's ascender/descender by a few
    /// points (notably CJK comments and code descenders). Reserve this space so
    /// the final visible line never sits under the following divider.
    private static let previewSafetyInset: CGFloat = 12

    static func cardSize(
        for entry: ClipboardEntry,
        imageURL: URL?,
        availableHeight: CGFloat,
        availableWidth: CGFloat
    ) -> NSSize {
        let width = preferredWidth(for: entry, availableWidth: availableWidth)
        let floor = minimumPreview(for: entry)
        let maximumPreview = max(floor, availableHeight - verticalChrome - screenMargin)
        let preview = previewHeight(
            for: entry,
            imageURL: imageURL,
            cardWidth: width,
            maximumHeight: maximumPreview
        )
        let desired = verticalChrome + preview
        let maximum = max(verticalChrome + floor, availableHeight - screenMargin)
        return NSSize(width: width, height: min(max(desired, verticalChrome + floor), maximum))
    }

    static func previewAreaHeight(cardHeight: CGFloat) -> CGFloat {
        max(minimumPreviewHeight, cardHeight - verticalChrome)
    }

    /// The FloatingPanel reserves this entire lane once. Individual cards may
    /// be narrower, but the host must not resize when the pointer moves from
    /// a one-line text item to a long code item.
    static func hostSlotWidth(availableWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(1, availableWidth))
    }

    private static func minimumPreview(for entry: ClipboardEntry) -> CGFloat {
        entry.kind == .image ? minimumImagePreviewHeight : minimumPreviewHeight
    }

    static func previewHeight(
        for entry: ClipboardEntry,
        imageURL: URL?,
        cardWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGFloat {
        let contentWidth = cardWidth - horizontalPadding * 2
        if entry.kind == .image, let imageURL, let image = NSImage(contentsOf: imageURL) {
            let size = image.representations.first.map {
                NSSize(width: $0.pixelsWide, height: $0.pixelsHigh)
            } ?? image.size
            guard size.width > 0, size.height > 0 else { return 140 }
            return min(maximumHeight, max(minimumPreviewHeight, contentWidth * size.height / size.width))
        }

        let isCode = entry.contentCategory == .code
        let font = isCode
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        let text = entry.text ?? entry.previewText
        if isCode {
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return min(ceil(bounds.height) + previewSafetyInset, maximumHeight)
        }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return max(lineHeight, min(ceil(bounds.height) + previewSafetyInset, maximumHeight))
    }

    /// Code gets just enough extra width to preserve ordinary source lines,
    /// then deliberately caps at a readable desktop-card size.  Text and image
    /// previews retain a compact card unless their source needs more room.
    private static func preferredWidth(for entry: ClipboardEntry, availableWidth: CGFloat) -> CGFloat {
        let text = entry.text ?? entry.previewText
        let isCode = entry.contentCategory == .code
        let font: NSFont = isCode
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        if !isCode {
            let target = (String(repeating: "中", count: readableTextCharactersPerLine) as NSString)
                .size(withAttributes: [.font: font]).width + horizontalPadding * 2
            let readable = min(maximumWidth, max(minimumWidth, target))
            return min(readable, max(1, availableWidth))
        }
        let longest = text
            .components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let preferred = longest + horizontalPadding * 2 + 2
        let desired = min(maximumWidth, max(minimumWidth, preferred))
        // Do not force the preview wider than the actually available side.
        // The former 260-pt floor made the united host cross the screen edge
        // and moved the list out from under the pointer.
        return min(desired, max(1, availableWidth))
    }
}

// MARK: - Panel content

struct ClipboardHistoryPanelView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject private var detailPresentation: ClipboardDetailPresentation
    let onDone: () -> Void
    let onContentChange: (CGFloat) -> Void
    let onDetailEntry: (ClipboardEntry?) -> Void
    let onAddToMemes: (ClipboardEntry) -> Void
    let onTogglePin: (ClipboardEntry) -> Void

    @State private var query = ""
    @State private var hoveredID: UUID?
    @State private var keyboardSelectedID: UUID?
    @State private var keyboardSelection = false
    @State private var hoverPreviewDelay = ClipboardHoverPreviewDelay()

    fileprivate init(
        store: ClipboardHistoryStore,
        detailPresentation: ClipboardDetailPresentation,
        onDone: @escaping () -> Void,
        onContentChange: @escaping (CGFloat) -> Void,
        onDetailEntry: @escaping (ClipboardEntry?) -> Void,
        onAddToMemes: @escaping (ClipboardEntry) -> Void,
        onTogglePin: @escaping (ClipboardEntry) -> Void
    ) {
        self.store = store
        _detailPresentation = ObservedObject(wrappedValue: detailPresentation)
        self.onDone = onDone
        self.onContentChange = onContentChange
        self.onDetailEntry = onDetailEntry
        self.onAddToMemes = onAddToMemes
        self.onTogglePin = onTogglePin
    }

    private var activeKey: ClipboardCategoryKey { store.settings.activeCategoryKey }
    private var entries: [ClipboardEntry] { store.orderedEntries(query: query, key: activeKey) }
    private var activeSelectionID: UUID? { hoveredID ?? keyboardSelectedID }

    var body: some View {
        GeometryReader { proxy in
            let currentMainHeight = detailPresentation.isVisible
                ? detailPresentation.mainHeight
                : proxy.size.height
            ZStack(alignment: .topLeading) {
                SystemGlassCard {
                    listContent
                        .frame(width: ClipboardPanelLayout.panelWidth, height: currentMainHeight)
                }
                .frame(width: ClipboardPanelLayout.panelWidth, height: currentMainHeight)
                .offset(x: mainCardXOffset, y: detailPresentation.mainTopOffset)

                detailCard
                    .offset(x: detailCardXOffset, y: detailPresentation.detailTopOffset)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private var mainCardXOffset: CGFloat {
        detailPresentation.isVisible && detailPresentation.placement == .left
            ? detailPresentation.sideSlotWidth + 10
            : 0
    }

    private var detailCardXOffset: CGFloat {
        switch detailPresentation.placement {
        case .left:
            // Keep the card's right edge next to the list. Empty lane space
            // sits on its outer edge so compact text does not look stretched.
            max(0, detailPresentation.sideSlotWidth - detailPresentation.cardSize.width)
        case .right:
            ClipboardPanelLayout.panelWidth + 10
        case .overlay:
            max(0, (ClipboardPanelLayout.panelWidth - detailPresentation.cardSize.width) / 2)
        }
    }

    private var listContent: some View {
        VStack(spacing: ClipboardPanelLayout.sectionSpacing) {
            PanelSearchField(placeholder: "搜索剪贴板", text: $query)
                .frame(height: ClipboardPanelLayout.headerHeight)
            categoryBar
                .frame(height: ClipboardPanelLayout.segmentedHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    content
                }
                .onChange(of: activeSelectionID) { _, id in
                    // Hover must never scroll the view underneath the pointer;
                    // doing so made a different cell appear selected. Only
                    // keyboard navigation is allowed to reveal an offscreen row.
                    if keyboardSelection, let id { proxy.scrollTo(id, anchor: .center) }
                    // Pointer previews deliberately wait for a dwell; keyboard
                    // navigation remains immediate because it has no hover
                    // affordance and users expect a selected row to inspect.
                    if keyboardSelection {
                        onDetailEntry(entries.first(where: { $0.id == id }))
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
                }
            }
        }
        .padding(ClipboardPanelLayout.outerPadding)
        .frame(width: ClipboardPanelLayout.panelWidth)
        // A non-activating panel's search field normally owns first responder,
        // so a zero-sized SwiftUI key view never sees navigation or command
        // keys.  This bridge installs a *window-scoped* local monitor instead:
        // ordinary text still reaches the search field, while clipboard
        // actions remain available no matter which control has focus.
        .background(KeyCaptureView { event in handleKey(event) }.frame(width: 1, height: 1))
        .onAppear {
            validateSelection()
            reportContentHeight()
        }
        .onChange(of: query) { _, _ in selectionAndSizeChanged() }
        .onChange(of: store.settings.lastCategory) { _, _ in selectionAndSizeChanged() }
        .onChange(of: activeKey.storageValue) { _, _ in selectionAndSizeChanged() }
        .onChange(of: store.entries) { _, _ in selectionAndSizeChanged() }
        .onDisappear { cancelPendingPreview() }
    }

    @ViewBuilder
    private var detailCard: some View {
        if let entry = detailPresentation.entry {
            SystemGlassCard {
                ClipboardDetailCard(
                    entry: entry,
                    imageURL: detailPresentation.imageURL,
                    cardSize: detailPresentation.cardSize,
                    codeHighlightTheme: store.settings.resolvedCodeHighlightTheme
                )
            }
            .frame(
                width: detailPresentation.cardSize.width,
                height: detailPresentation.cardSize.height,
                alignment: .topLeading
            )
        }
    }

    private var emptyTitle: String {
        switch activeKey {
        case .builtin(let category):
            switch category {
            case .image: "没有图片记录"
            case .screenshot: "没有截图记录"
            case .text: "没有文本记录"
            case .code: "没有代码记录"
            case .link: "没有链接记录"
            }
        case .custom:
            "没有匹配的记录"
        }
    }

    private var emptySymbol: String {
        switch activeKey {
        case .builtin(let category): category.systemImage
        case .custom: "tag"
        }
    }

    private func selectionAndSizeChanged() {
        validateSelection()
        // A category/query change replaces the list, so a preview of the old
        // entry is invalid. Collapse it before calculating the new category's
        // height; otherwise the controller deliberately ignores a resize while
        // a detail slideout is visible.
        onDetailEntry(nil)
        DispatchQueue.main.async { reportContentHeight() }
    }

    private func reportContentHeight() {
        onContentChange(ClipboardPanelLayout.contentHeight(for: entries, key: activeKey))
    }

    private func title(for key: ClipboardCategoryKey) -> String {
        switch key {
        case .builtin(let category): category.displayName
        case .custom(let id): store.settings.customCategory(id: id)?.name ?? "自定义"
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.settings.enabledCategoryKeys, id: \.storageValue) { key in
                    CategoryChip(title: title(for: key), isSelected: activeKey == key) {
                        store.settings.activeCategoryKey = key
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch activeKey {
        case .builtin(.image), .builtin(.screenshot):
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(ClipboardPanelLayout.imageCellSide), spacing: ClipboardPanelLayout.imageCellSpacing),
                    count: ClipboardPanelLayout.imageColumns
                ),
                alignment: .leading,
                spacing: ClipboardPanelLayout.imageCellSpacing
            ) {
                ForEach(entries) { entry in
                    ImageEntryCell(
                        entry: entry,
                        imageURL: store.imageURL(for: entry),
                        isSelected: activeSelectionID == entry.id,
                        onTogglePin: { onTogglePin(entry) }
                    )
                    .id(entry.id)
                    .onTapGesture { copy(entry) }
                    .overlay {
                        EntryHoverTrackingOverlay { updateHover($0, entry: entry) }
                    }
                    .contextMenu { entryMenu(entry) }
                }
            }
        default:
            LazyVStack(spacing: ClipboardPanelLayout.listSpacing) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(spacing: 0) {
                        if activeKey == .builtin(.code) {
                            CodeEntryRow(
                                entry: entry,
                                isSelected: activeSelectionID == entry.id,
                                codeHighlightTheme: store.settings.resolvedCodeHighlightTheme,
                                onTogglePin: { onTogglePin(entry) }
                            )
                        } else {
                            TextEntryRow(
                                entry: entry,
                                isSelected: activeSelectionID == entry.id,
                                onTogglePin: { onTogglePin(entry) }
                            )
                        }
                        if activeKey == .builtin(.code), index < entries.count - 1 {
                            Divider()
                                .padding(.horizontal, 10)
                        }
                    }
                    .id(entry.id)
                    .contentShape(Rectangle())
                    // macOS 26 can drop SwiftUI's hover tracking for a view
                    // whose background is fully clear.  Maccy keeps an
                    // imperceptible backing layer for exactly this reason.
                    // This is a hit-testing surface only: it must never turn
                    // white or change the panel material on hover.
                    .background(Color.white.opacity(0.001))
                    .onTapGesture { copy(entry) }
                    .overlay {
                        EntryHoverTrackingOverlay { updateHover($0, entry: entry) }
                    }
                    .contextMenu { entryMenu(entry) }
                }
            }
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: ClipboardEntry) -> some View {
        if entry.kind == .image {
            Button {
                onAddToMemes(entry)
            } label: {
                Label("添加到表情包", systemImage: "photo.badge.plus")
            }
            Divider()
        }
        Button(entry.isPinned ? "取消置顶" : "置顶") { store.togglePinned(id: entry.id) }
        Button(entry.isDesktopPinned == true ? "取消桌面固定" : "固定到桌面") { onTogglePin(entry) }
        Button("删除", role: .destructive) { delete(entry) }
    }

    private func validateSelection() {
        let ids = Set(entries.map(\.id))
        if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
        if let keyboardSelectedID, !ids.contains(keyboardSelectedID) { self.keyboardSelectedID = nil }
    }

    private func updateHover(_ isHovered: Bool, entry: ClipboardEntry) {
        if isHovered {
            keyboardSelection = false
            keyboardSelectedID = nil
            hoveredID = entry.id
            schedulePreview(for: entry)
        } else if hoveredID == entry.id {
            // Keep the visual selection alive until the exit is confirmed.
            // A preview expansion can replace a tracking area momentarily;
            // clearing this state immediately made the blue row disappear
            // while its preview was still visible.
            let hoveredIDBinding = $hoveredID
            hoverPreviewDelay.scheduleExit(entry: entry) { [onDetailEntry] in
                if hoveredIDBinding.wrappedValue == entry.id {
                    hoveredIDBinding.wrappedValue = nil
                }
                onDetailEntry(nil)
            }
        }
    }

    private func schedulePreview(for entry: ClipboardEntry) {
        hoverPreviewDelay.schedule(entry: entry) { [onDetailEntry] in
            // The delay object verifies the entry ID before calling back, so a
            // timer from a previous row cannot open after the pointer moved.
            onDetailEntry(entry)
        }
    }

    private func cancelPendingPreview() {
        hoverPreviewDelay.cancel()
    }

    private func copy(_ entry: ClipboardEntry) {
        _ = store.copyToPasteboard(entry, autoPaste: store.settings.autoPaste)
        onDone()
    }

    private func delete(_ entry: ClipboardEntry) {
        store.delete(id: entry.id)
        validateSelection()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
            if store.copyPinned(number: number, autoPaste: store.settings.autoPaste) {
                onDone()
            }
            return true
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p", let selectedID = activeSelectionID {
            store.togglePinned(id: selectedID)
            return true
        }
        let columns = (activeKey == .builtin(.image) || activeKey == .builtin(.screenshot))
            ? ClipboardPanelLayout.imageColumns
            : 1
        switch event.keyCode {
        case 36, 76:
            guard let entry = entries.first(where: { $0.id == activeSelectionID }) else { return true }
            copy(entry)
            return true
        case 51, 117:
            if let entry = entries.first(where: { $0.id == activeSelectionID }) { delete(entry) }
            return true
        case 53:
            onDone()
            return true
        case 123:
            moveSelection(delta: -1)
            return true
        case 124:
            moveSelection(delta: 1)
            return true
        case 125:
            moveSelection(delta: columns)
            return true
        case 126:
            moveSelection(delta: -columns)
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int) {
        guard !entries.isEmpty else { return }
        let nextIndex: Int
        if let currentIndex = activeSelectionID.flatMap({ id in entries.firstIndex(where: { $0.id == id }) }) {
            nextIndex = min(max(currentIndex + delta, 0), entries.count - 1)
        } else {
            nextIndex = 0
        }
        keyboardSelection = true
        hoveredID = nil
        keyboardSelectedID = entries[nextIndex].id
    }
}

// MARK: - Rows

private struct TextEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let onTogglePin: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.previewText.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
            if isSelected || isHovered || entry.isDesktopPinned == true {
                ClipboardPinButton(entry: entry, isSelected: isSelected, action: onTogglePin)
            }
            if entry.isPinned && !isSelected {
                ClipboardHistoryPinIcon()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardPanelLayout.textRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // The row remains hit-testable because its layout frame is
                // explicit; a near-white fallback fill here used to become
                // visible during AppKit hover compositing and made the panel
                // flash white under the pointer.
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
        .onHover { isHovered = $0 }
    }
}

private struct CodeEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let codeHighlightTheme: CodeHighlightTheme
    let onTogglePin: () -> Void

    @State private var isHovered = false

    private var lineCount: Int { ClipboardPanelLayout.previewLineCount(entry.text) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(CodeHighlighter.highlight(previewCode, theme: codeHighlightTheme))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(ClipboardPanelLayout.codePreviewMaxLines)
                .lineSpacing(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
            if isSelected || isHovered || entry.isDesktopPinned == true {
                ClipboardPinButton(entry: entry, isSelected: isSelected, action: onTogglePin)
            }
            if entry.isPinned && !isSelected {
                ClipboardHistoryPinIcon()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardPanelLayout.codeRowHeight(lineCount: lineCount), alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
        .onHover { isHovered = $0 }
    }

    private var previewCode: String {
        ClipboardPanelLayout.codePreviewLines(entry.text).joined(separator: "\n")
    }
}

private struct ImageEntryCell: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let isSelected: Bool
    let onTogglePin: () -> Void

    @State private var isHovered = false

    private var side: CGFloat { ClipboardPanelLayout.imageCellSide }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
            if let imageURL {
                AnimatedImageFileView(url: imageURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(3)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            if isSelected || isHovered || entry.isDesktopPinned == true {
                ClipboardPinButton(entry: entry, isSelected: true, action: onTogglePin)
                    .background(Circle().fill(.black.opacity(0.4)))
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if entry.isPinned && !isSelected {
                ClipboardHistoryPinIcon()
                    .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .onHover { isHovered = $0 }
    }
}

private struct ClipboardPinButton: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // A window glyph means "pin as a desktop window". The plain pin
            // at a row's far-right edge is reserved for clipboard ordering.
            Image(systemName: entry.isDesktopPinned == true ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .help(entry.isDesktopPinned == true ? "取消桌面固定" : "固定到桌面")
        .accessibilityLabel(entry.isDesktopPinned == true ? "取消桌面固定" : "固定到桌面")
    }
}

/// The clipboard-order pin is intentionally non-interactive and lives at the
/// final trailing edge of every unselected text/code row. It disappears under
/// the blue selection highlight so the selected-row affordances stay clean.
private struct ClipboardHistoryPinIcon: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .frame(width: 18, height: 18)
            .help("剪贴板内置顶")
            .accessibilityLabel("剪贴板内置顶")
    }
}

/// AppKit-backed row tracking for the non-activating clipboard panel.
/// SwiftUI's `onHover` can miss an enter transition on macOS 26 when a hosted
/// view is rebuilt under a stationary pointer.  A tracking area also receives
/// mouse-moved events and re-evaluates its bounds, so remaining on an entry is
/// sufficient to start the preview timer even after a list/layout refresh.
private struct EntryHoverTrackingOverlay: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHover = onHover
        nsView.refreshHoverState()
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isInside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
            refreshHoverState()
        }

        override func mouseEntered(with event: NSEvent) {
            // AppKit can synthesize enter/exit pairs while the hosting view
            // changes geometry. Use the actual pointer position instead.
            refreshHoverState()
        }

        override func mouseExited(with event: NSEvent) {
            refreshHoverState()
        }

        override func mouseMoved(with event: NSEvent) {
            refreshHoverState()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Tracking must never consume clicks, context menus, scrolling, or
            // the desktop-pin control placed in the same row.
            nil
        }

        func refreshHoverState() {
            guard let window else {
                setHovered(false)
                return
            }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let localPoint = convert(windowPoint, from: nil)
            setHovered(bounds.contains(localPoint))
        }

        private func setHovered(_ hovered: Bool) {
            guard isInside != hovered else { return }
            isInside = hovered
            onHover?(hovered)
        }
    }
}

// MARK: - Key capture

private struct KeyCaptureView: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CapturingView {
        let view = CapturingView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: CapturingView, context: Context) {
        nsView.onKey = onKey
    }

    final class CapturingView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var keyEventMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeKeyEventMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeKeyEventMonitor()
            installKeyEventMonitor()
        }

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }

        /// Keep command/navigation routing in the panel even while the search
        /// field is first responder.  Limiting the monitor to this exact
        /// window is important: the app's global hotkeys and every other
        /// window retain their normal responder-chain behavior.
        private func installKeyEventMonitor() {
            guard keyEventMonitor == nil, window != nil else { return }
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      window.isVisible else {
                    return event
                }
                return self.onKey?(event) == true ? nil : event
            }
        }

        private func removeKeyEventMonitor() {
            if let keyEventMonitor {
                NSEvent.removeMonitor(keyEventMonitor)
                self.keyEventMonitor = nil
            }
        }
    }
}
