import AppKit
import HedgeMemoCore
import SwiftUI

/// Adds a stable display offset before the bounded visible page is handed to
/// SwiftUI. SwiftUI still keys every row by the entry's real ID.
private struct IndexedElements<Base: RandomAccessCollection>: RandomAccessCollection
where Base.Index == Int, Base.Element: Identifiable {
    struct Item: Identifiable {
        let offset: Int
        let element: Base.Element
        var id: Base.Element.ID { element.id }
    }

    let base: Base

    var startIndex: Int { base.startIndex }
    var endIndex: Int { base.endIndex }

    subscript(position: Int) -> Item {
        Item(
            offset: base.distance(from: base.startIndex, to: position),
            element: base[position]
        )
    }
}

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
        /// Vertical location of the selected row inside the detail card. This
        /// keeps the directional arrow aligned if the card is screen-clamped.
        let pointerOffsetY: CGFloat

        static let hidden = State(
            entry: nil,
            imageURL: nil,
            cardSize: .zero,
            sideSlotWidth: 0,
            placement: .right,
            mainTopOffset: 0,
            mainHeight: 0,
            detailTopOffset: 0,
            pointerOffsetY: 0
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
    var pointerOffsetY: CGFloat { state.pointerOffsetY }
    var isVisible: Bool { state.entry != nil }

    func show(
        entry: ClipboardEntry,
        imageURL: URL?,
        cardSize: NSSize,
        sideSlotWidth: CGFloat,
        placement: Placement,
        mainTopOffset: CGFloat,
        mainHeight: CGFloat,
        detailTopOffset: CGFloat,
        pointerOffsetY: CGFloat
    ) {
        state = State(
            entry: entry,
            imageURL: imageURL,
            cardSize: cardSize,
            sideSlotWidth: sideSlotWidth,
            placement: placement,
            mainTopOffset: mainTopOffset,
            mainHeight: mainHeight,
            detailTopOffset: detailTopOffset,
            pointerOffsetY: pointerOffsetY
        )
    }

    func hide() {
        // Publishing an unchanged `.hidden` re-rendered the entire panel on
        // every hover exit (each row exit schedules a close); only publish a
        // real visible → hidden transition.
        guard state.entry != nil else { return }
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

/// Pure geometry for wrapping existing category controls. Interactive elements
/// remain native SwiftUI Buttons/Pickers; this helper only decides which
/// category titles fit on each row and reserves the trailing controls on the
/// final row.
private enum ClipboardCategoryBarMetrics {
    static let lineSpacing: CGFloat = 6
    private static let itemSpacing: CGFloat = 6
    private static let chipHorizontalPadding: CGFloat = 20
    private static let availableWidth =
        ClipboardPanelLayout.panelWidth - ClipboardPanelLayout.outerPadding * 2

    static func title(
        for key: ClipboardCategoryKey,
        settings: ClipboardHistorySettings
    ) -> String {
        switch key {
        case .builtin(let category):
            category.displayName
        case .custom(let id):
            settings.customCategory(id: id)?.name ?? L10n.text("自定义")
        }
    }

    static func rows(
        settings: ClipboardHistorySettings,
        queueCount: Int
    ) -> [[ClipboardCategoryKey]] {
        let keys = settings.enabledCategoryKeys
        guard !keys.isEmpty else { return [[]] }
        let widths = Dictionary(uniqueKeysWithValues: keys.map {
            ($0.storageValue, chipWidth(title(for: $0, settings: settings)))
        })

        var rows: [[ClipboardCategoryKey]] = []
        var current: [ClipboardCategoryKey] = []
        var currentWidth: CGFloat = 0
        for key in keys {
            let width = widths[key.storageValue] ?? 44
            let needed = current.isEmpty ? width : currentWidth + itemSpacing + width
            if !current.isEmpty, needed > availableWidth {
                rows.append(current)
                current = [key]
                currentWidth = width
            } else {
                current.append(key)
                currentWidth = needed
            }
        }
        if !current.isEmpty { rows.append(current) }

        let finalCapacity = max(80, availableWidth - accessoryWidth(queueCount: queueCount))
        guard let last = rows.last,
              rowWidth(last, widths: widths) > finalCapacity,
              last.count > 1 else {
            return rows
        }

        var preceding = last
        var final: [ClipboardCategoryKey] = []
        while let candidate = preceding.last {
            let candidateWidth = widths[candidate.storageValue] ?? 44
            let nextWidth = final.isEmpty
                ? candidateWidth
                : candidateWidth + itemSpacing + rowWidth(final, widths: widths)
            guard final.isEmpty || nextWidth <= finalCapacity else { break }
            preceding.removeLast()
            final.insert(candidate, at: 0)
        }
        rows.removeLast()
        if !preceding.isEmpty { rows.append(preceding) }
        if !final.isEmpty { rows.append(final) }
        return rows
    }

    static func height(settings: ClipboardHistorySettings, queueCount: Int) -> CGFloat {
        let count = max(1, rows(settings: settings, queueCount: queueCount).count)
        return CGFloat(count) * ClipboardPanelLayout.segmentedHeight
            + CGFloat(count - 1) * lineSpacing
    }

    private static func chipWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
            + chipHorizontalPadding
    }

    private static func rowWidth(
        _ row: [ClipboardCategoryKey],
        widths: [String: CGFloat]
    ) -> CGFloat {
        row.enumerated().reduce(CGFloat.zero) { total, pair in
            total
                + (pair.offset == 0 ? 0 : itemSpacing)
                + (widths[pair.element.storageValue] ?? 44)
        }
    }

    private static func accessoryWidth(queueCount: Int) -> CGFloat {
        let queueTextWidth: CGFloat
        if queueCount > 0 {
            queueTextWidth = ceil(
                ("\(queueCount)" as NSString).size(
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]
                ).width
            ) + 18
        } else {
            queueTextWidth = 26
        }
        return queueTextWidth + itemSpacing + 28 + itemSpacing
    }
}

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardHistoryStore
    private let lockStore: AppLockStore
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

    init(store: ClipboardHistoryStore, lockStore: AppLockStore, memeStore: MemeStore) {
        self.store = store
        self.lockStore = lockStore
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
        guard let panel else { return }
        panel.orderOut(nil)
        // The hidden hosting tree otherwise retains its visible NSImageViews,
        // highlighted strings and row state indefinitely. Rebuilding this small
        // transient panel on demand trades a little open-time setup for a much
        // smaller true background footprint.
        TransientPanelLifetime.release(panel)
        self.panel = nil
        mainSurface = nil
        mainScreenFrame = .zero
        pendingProgrammaticFrame = nil
        store.releaseTransientCaches()
        ImageThumbnailCache.shared.scheduleIdlePurge()
    }

    private func show() {
        ImageThumbnailCache.shared.beginInteractiveUse()
        let key = store.settings.activeCategoryKey
        if key == .builtin(.password) || lockStore.settings.isCategoryLocked(key) {
            lockStore.prepareVaultAccess()
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        let content = ClipboardHistoryPanelView(
            store: store,
            lockStore: lockStore,
            detailPresentation: detailPresentation,
            onDone: { [weak self] in self?.hide() },
            onContentChange: { [weak self] contentHeight, categoryBarHeight in
                self?.requestMainResize(
                    contentHeight: contentHeight,
                    categoryBarHeight: categoryBarHeight
                )
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
        // A locked category shows the PIN gate, not a list, so its height comes
        // from the gate. Sizing from the (hidden) entries here made the panel
        // open at the wrong height and then jump as soon as the view reported
        // its real content height.
        let initialContentHeight: CGFloat
        if lockStore.isCategoryLocked(key) {
            initialContentHeight = ClipboardPanelLayout.lockedStateHeight
        } else {
            let ordered = store.orderedEntries(
                key: key,
                advancedOptions: store.settings.resolvedAdvancedOptions
            )
            let pageLimit = ClipboardPanelPagination.initialLimit(for: key)
            let heightEntries = ordered.prefix(min(pageLimit, ordered.count))
            initialContentHeight = ClipboardPanelLayout.contentHeight(for: heightEntries, key: key)
        }
        let initialCategoryBarHeight = ClipboardCategoryBarMetrics.height(
            settings: store.settings,
            queueCount: store.pasteQueueCount
        )
        resize(
            contentHeight: initialContentHeight
                + initialCategoryBarHeight
                - ClipboardPanelLayout.segmentedHeight,
            animate: false
        )
        position(panel)
        // Match the reference popup's activation contract. The material is
        // fixed by PanelMaterialHost; becoming key must not replace it with a
        // second focus/hover surface.
        TextCompletionCrashGuard.prepareToOrderOnScreen(panel)
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

    private func setPanelFrame(_ frame: NSRect, display: Bool = true, animated: Bool = false) {
        guard let panel else { return }
        pendingProgrammaticFrame = frame
        if animated {
            // Height changes between categories are eased instead of snapping.
            // The hosted content is sized from this window's own geometry (see
            // the GeometryReader in `body`), so it follows the animator frame by
            // frame and the glass surface never renders a mismatched size —
            // which is what an animated `setFrame(animate:)` used to produce.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: display)
            }
        } else {
            panel.setFrame(frame, display: display, animate: false)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
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
    /// Short enough to feel immediate, long enough to read as a stretch.
    private static let resizeDuration: TimeInterval = 0.22

    private func resize(contentHeight: CGFloat, animate: Bool) {
        guard let panel else { return }
        let visibleFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let height = ClipboardPanelLayout.panelHeight(
            contentHeight: contentHeight,
            availableHeight: visibleFrame.height - panelInset * 2,
            advancedMode: store.settings.resolvedAdvancedModeEnabled
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
        // Content-height reports arrive on every selection/query change; when
        // nothing actually moves, skip the window commit — a same-frame
        // `setFrame` still forces a full glass redraw.
        if framesMatch(frame, panel.frame) {
            mainScreenFrame = frame
            return
        }
        // Native NSWindow frame animation and a hosted NSGlassEffectView do
        // not share one layout transaction.  Rendering the interpolated frame
        // was the source of the occasional compressed, horizontal-strip panel.
        // The SwiftUI content change is already animated where appropriate;
        // commit the host geometry atomically instead.
        setPanelFrame(frame, animated: animate)
        mainScreenFrame = frame
    }

    private func requestMainResize(
        contentHeight: CGFloat,
        categoryBarHeight: CGFloat
    ) {
        guard panel != nil else { return }
        if detailPresentation.isVisible { return }
        resize(
            contentHeight: contentHeight
                + categoryBarHeight
                - ClipboardPanelLayout.segmentedHeight,
            animate: true
        )
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
        let detailTopOffset = placement == .overlay
            ? max(0, min(mainFrame.height - size.height, detailY - mainFrame.minY))
            : hostFrame.maxY - detailY - size.height
        // During a pointer preview the cursor is over the selected row. Keep
        // that vertical relationship if the detail card is clamped at a screen
        // edge, so its arrow still points at the selected row rather than the
        // card's geometric center.
        let pointerOffsetY = min(
            max(hostFrame.maxY - mouseY - detailTopOffset, ClipboardDetailPointer.height / 2),
            size.height - ClipboardDetailPointer.height / 2
        )
        detailPresentation.show(
            entry: entry,
            imageURL: imageURL,
            cardSize: size,
            sideSlotWidth: sideSlotWidth,
            placement: placement,
            mainTopOffset: hostFrame.maxY - mainFrame.maxY,
            mainHeight: mainFrame.height,
            detailTopOffset: detailTopOffset,
            pointerOffsetY: pointerOffsetY
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
        let wasVisible = detailPresentation.isVisible
        detailPresentation.hide()
        // Hover exits schedule a close even when no preview ever opened; doing
        // a same-frame `setFrame` (and its full glass redraw) on each of those
        // is what made the row highlight lag behind the pointer.
        guard wasVisible, let panel, !mainScreenFrame.isEmpty else { return }
        if !framesMatch(panel.frame, mainScreenFrame) {
            setPanelFrame(mainScreenFrame)
        }
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

    /// Deterministic visual fixture for the advanced category-row controls.
    /// Preview injection disables persistence, so this never changes the
    /// user's history or saved filter choices.
    func previewAdvancedMode() {
        let safari = ClipboardSourceApplication(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari"
        )
        let notes = ClipboardSourceApplication(
            bundleIdentifier: "com.apple.Notes",
            displayName: "Notes"
        )
        let now = Date()
        let fakes = (0..<14).map { index in
            let source = index.isMultiple(of: 2) ? safari : notes
            return ClipboardEntry(
                kind: .text,
                text: "高级筛选示例 \(index + 1)",
                contentHash: "advanced-preview-\(index)",
                createdAt: now.addingTimeInterval(-Double(index) * 60),
                lastUsedAt: index.isMultiple(of: 3)
                    ? nil
                    : now.addingTimeInterval(-Double(index) * 12),
                useCount: index * 3,
                sourceApp: source.displayName,
                sourceBundleIdentifier: source.bundleIdentifier
            )
        }
        store.injectPreviewEntries(fakes)
        store.settings.customCategories = [
            CustomClipboardCategory(name: "工作资料", pattern: "示例"),
            CustomClipboardCategory(name: "稍后阅读", pattern: "示例"),
            CustomClipboardCategory(name: "项目参考链接", pattern: "示例"),
            CustomClipboardCategory(name: "临时收集", pattern: "示例"),
        ]
        store.settings.activeCategoryKey = .builtin(.text)
        store.settings.advancedModeEnabled = true
        store.settings.advancedSourceIdentifier = nil
        store.settings.advancedSortField = .useCount
        store.settings.advancedSortDirection = .descending
        show()
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

/// Eases the preview card in with a small scale-and-fade "pop" instead of
/// snapping into place.  It animates from its own `onAppear`, so it plays once
/// per hover session (a genuine insertion) and never re-triggers while the
/// pointer glides between rows and the card is only re-sized.
private struct DetailCardPopIn: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.74)) {
                    appeared = true
                }
            }
    }
}

/// The footer shortcut hint. Kept in one place so the rendered string and the
/// width the layout reserves for it can never drift apart.
private enum ClipboardShortcutHint {
    /// Copying still works via Return — this hint just no longer advertises it,
    /// since the footer only has room for one entry-point shortcut and editing
    /// is the one worth surfacing. "编辑" only applies to text-kind entries
    /// (images have no editable text body), so it is omitted for images rather
    /// than shown as a dead shortcut.
    static func text(
        kind: ClipboardEntryKind,
        isSecret: Bool,
        isPinned: Bool,
        isDesktopPinned: Bool
    ) -> String {
        let pin = L10n.text(isPinned ? "取消置顶" : "置顶")
        let desktop = L10n.text(isDesktopPinned ? "取消固定" : "固定桌面")
        var segments = [String]()
        if kind == .text, !isSecret { segments.append(L10n.text("编辑：⌘E")) }
        segments.append(L10n.text("删除：⌫"))
        segments.append("\(pin)：⌘P")
        segments.append("\(desktop)：⌥P")
        return segments.joined(separator: " ｜ ")
    }

    /// Shown instead of the normal hint line while editing.
    static var editing: String { L10n.text("按 ⌘S 保存并退出") }

    /// The widest variant (a text entry, both toggles in their longer "cancel"
    /// wording); the card minimum width is sized to this so the hint never
    /// truncates. `editing` is always shorter, so it needs no floor of its own.
    static var widest: String {
        text(kind: .text, isSecret: false, isPinned: true, isDesktopPinned: true)
    }

    /// Matches the footer `Text`'s `.font(.system(size: 10))`, for measurement.
    static var font: NSFont { .systemFont(ofSize: 10) }
}

private struct ClipboardDetailCard: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let cardSize: NSSize
    let codeHighlightTheme: CodeHighlightTheme
    let isEditing: Bool
    @Binding var editText: String

    @FocusState private var isEditorFocused: Bool
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                sourceRow
                detailRow(L10n.text("收录时间"), entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow(L10n.text("上次使用"), entry.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? L10n.text("还未使用"))
                detailRow(L10n.text("使用次数"), L10n.format("使用次数格式", entry.useCount ?? 0))
            }
            Divider()
            // Shortcut hints share one line in a "动作：按键" format, the actions
            // separated by " ｜ ". The card min width reserves room for this line
            // so it never truncates.
            Text(
                isEditing
                    ? ClipboardShortcutHint.editing
                    : ClipboardShortcutHint.text(
                        kind: entry.kind,
                        isSecret: entry.isSecret,
                        isPinned: entry.isPinned,
                        isDesktopPinned: entry.isDesktopPinned == true
                    )
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
        // Covers both routes into edit mode: a fresh detail card that already
        // starts out editing (⌘E forced the preview open) and an existing,
        // already-visible card that transitions into editing in place.
        .onAppear {
            guard isEditing else { return }
            DispatchQueue.main.async { isEditorFocused = true }
        }
        .onChange(of: isEditing) { _, editing in
            guard editing else { return }
            DispatchQueue.main.async { isEditorFocused = true }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if isEditing, entry.contentCategory == .code {
            // Code keeps syntax highlighting while editing and offers inline
            // keyword completion (Tab to accept).
            CodeTextEditor(
                text: $editText,
                theme: codeHighlightTheme,
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                showsScrollIndicators: showsScrollIndicators
            )
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            )
            .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
        } else if isEditing, entry.kind == .text {
            // A real TextEditor rather than a Text: typing, selection, cut/copy/
            // paste, undo and arrow-key navigation all come for free from
            // AppKit's text system. Its own scrolling handles content that
            // outgrows the fixed card height — a read-only preview never needs
            // that, since it never grows once it's on screen.
            TextEditor(text: $editText)
                .disablesRemoteTextCompletion()
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
                .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
                .focused($isEditorFocused)
        } else if entry.kind == .image, let imageURL {
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
            .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
            .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
        } else {
            ScrollView(.vertical) {
                Text(entry.text ?? entry.previewText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
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
            Text(L10n.text("来源"))
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
            Text(name ?? L10n.text("未知"))
                .multilineTextAlignment(.trailing)
        }
    }
}

@MainActor
enum SourceApplicationIcon {
    /// Resolving an icon scans every running app and can touch the filesystem.
    /// Hovering the same handful of source apps repeatedly would redo that work
    /// on each preview, so memoize per name (including the "not found" result,
    /// stored as NSNull) for the session.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private static var unresolvedNames = Set<String>()

    static func image(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        if unresolvedNames.contains(name) { return nil }
        let resolved = resolve(name: name)
        if let resolved {
            let pixels = resolved.representations
                .map { max(1, $0.pixelsWide) * max(1, $0.pixelsHigh) }
                .max() ?? 1
            cache.setObject(resolved, forKey: name as NSString, cost: pixels * 4)
        } else {
            // Negative lookups are cheap strings, but still bounded so changing
            // application installs cannot grow a permanent session table.
            if unresolvedNames.count >= 64 { unresolvedNames.removeAll(keepingCapacity: true) }
            unresolvedNames.insert(name)
        }
        return resolved
    }

    static func releaseTransientCache() {
        cache.removeAllObjects()
        unresolvedNames.removeAll(keepingCapacity: false)
    }

    private static func resolve(name: String) -> NSImage? {
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
    private static let maximumWidth: CGFloat = 720
    /// The widest a wrapped text line is ever allowed to grow.  Long text wraps
    /// at roughly thirty Chinese glyphs per row so a line never becomes an
    /// unreadable single stretch, while short text is free to be narrower.
    private static let readableTextCharactersPerLine = 30
    private static let horizontalPadding: CGFloat = 12
    // Includes the two dividers, metadata rows, the single shortcut-hint line
    // and the card padding.  Dropping the "类型" metadata row and collapsing the
    // two shortcut lines into one each removed a line from the chrome.
    private static let verticalChrome: CGFloat = 146

    /// The card must stay wide enough that the metadata rows below the preview
    /// (source, capture time, last-used) never squeeze their label against
    /// their value.  Derived from the widest predictable row — a label plus a
    /// fully populated, locale-formatted date — so short previews can be narrow
    /// without cramping this footer.
    private static var metadataMinimumWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        let widestLabel = L10n.text("收录时间")
        // Measure a value produced by the same formatter the rows use rather
        // than hard-coding, so the floor tracks the user's locale and clock.
        let sampleValue = Date(timeIntervalSince1970: 1_703_772_480)
            .formatted(date: .abbreviated, time: .shortened)
        let labelWidth = (widestLabel as NSString).size(withAttributes: [.font: font]).width
        let valueWidth = (sampleValue as NSString).size(withAttributes: [.font: font]).width
        // HStack spacing on each side of the Spacer plus its own minimum length.
        let rowSpacing: CGFloat = 6 + 4 + 6
        return ceil(labelWidth + valueWidth + rowSpacing) + horizontalPadding * 2
    }

    /// The single-line footer shortcut hint must fit without truncating, so its
    /// widest wording sets a floor on the card width.
    private static var instructionMinimumWidth: CGFloat {
        let width = (ClipboardShortcutHint.widest as NSString)
            .size(withAttributes: [.font: ClipboardShortcutHint.font]).width
        return ceil(width) + horizontalPadding * 2
    }

    /// The narrowest a card may be: enough for the metadata rows *and* the
    /// footer hint, whichever needs more room.
    private static var cardMinimumWidth: CGFloat {
        max(metadataMinimumWidth, instructionMinimumWidth)
    }
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
        if entry.kind == .image, let imageURL, let size = imagePixelSize(of: imageURL) {
            guard size.width > 0, size.height > 0 else { return 140 }
            return min(maximumHeight, max(minimumPreviewHeight, contentWidth * size.height / size.width))
        }

        let isCode = entry.contentCategory == .code
        let font = isCode
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        let text = measurementText(for: entry)
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

    /// Chooses the card width so the preview neither leaves a wide blank margin
    /// beside short snippets nor squashes long text into a single stretched
    /// line.  Both text and code shrink to fit their content, wrap long content
    /// into evenly balanced lines, and never drop below the width the metadata
    /// rows and footer hint need.
    /// A 40k-character prefix already wraps to far more lines than any screen
    /// can show and far exceeds the width caps, so measuring beyond it cannot
    /// change the resulting card size — but TextKit laying out a whole
    /// multi-megabyte clipboard text made the hover preview hitch.
    private static let measurementCharacterLimit = 40_000

    private static func measurementText(for entry: ClipboardEntry) -> String {
        String((entry.text ?? entry.previewText).prefix(measurementCharacterLimit))
    }

    private static func preferredWidth(for entry: ClipboardEntry, availableWidth: CGFloat) -> CGFloat {
        let text = measurementText(for: entry)
        let isCode = entry.contentCategory == .code
        let font: NSFont = isCode
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        let clampToScreen = { (width: CGFloat) in min(width, max(1, availableWidth)) }

        // Code is laid out verbatim: keep whole source lines intact up to the
        // readable cap so indentation and structure survive.
        if isCode {
            let longest = text
                .components(separatedBy: .newlines)
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            let preferred = longest + horizontalPadding * 2 + 2
            let desired = min(maximumWidth, max(cardMinimumWidth, preferred))
            return clampToScreen(desired)
        }

        // Text: pick a content width that balances the number of wrapped lines.
        // `cap` is the widest a line may get; `singleLine` is how wide the text
        // would be with no wrapping at all.
        let cap = (String(repeating: "中", count: readableTextCharactersPerLine) as NSString)
            .size(withAttributes: [.font: font]).width
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let singleLine = ceil((flattened as NSString).size(withAttributes: [.font: font]).width)

        // A hard-wrapped source line that already fits should not be re-wrapped
        // narrower than it is, otherwise its own newlines would fragment it.
        let hardLines = text.components(separatedBy: .newlines)
        let longestHardLine = hardLines
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        let content = ClipboardPanelLayout.balancedPreviewContentWidth(
            singleLineWidth: singleLine,
            cap: cap,
            longestHardLineWidth: longestHardLine,
            hasHardBreaks: hardLines.count > 1
        )
        let desired = max(cardMinimumWidth, content + horizontalPadding * 2)
        return clampToScreen(min(maximumWidth, desired))
    }
}

// MARK: - Panel content

/// A small directional bridge between the selected clipboard row and its
/// side-preview. It is only used when the preview has room to sit beside the
/// list; overlay previews intentionally have no misleading source direction.
private struct ClipboardDetailPointer: Shape {
    static let width: CGFloat = 14
    static let height: CGFloat = 22

    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsRight {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct ClipboardHistoryPanelView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var lockStore: AppLockStore
    @ObservedObject private var detailPresentation: ClipboardDetailPresentation
    let onDone: () -> Void
    let onContentChange: (CGFloat, CGFloat) -> Void
    let onDetailEntry: (ClipboardEntry?) -> Void
    let onAddToMemes: (ClipboardEntry) -> Void
    let onTogglePin: (ClipboardEntry) -> Void

    @State private var query = ""
    @State private var hoveredID: UUID?
    @State private var keyboardSelectedID: UUID?
    @State private var keyboardSelection = false
    /// A contextual menu owns selection until its complete native tracking
    /// session ends. Without this lock, moving through the menu can cross rows
    /// underneath it and make actions appear to target a different entry.
    @State private var contextMenuEntryID: UUID?
    @State private var contextMenuTrackingDepth = 0
    @State private var hoverPreviewDelay = ClipboardHoverPreviewDelay()
    @State private var pendingCommandCopyID: UUID?
    @State private var queueError: String?
    /// The entry currently open for in-place editing, if any. Non-nil forces
    /// the detail card to stay showing that entry (see `updateHover` and
    /// `selectionAndSizeChanged`), so a stray hover or list refresh mid-edit
    /// cannot silently swap the preview out from under an unsaved draft.
    @State private var editingEntryID: UUID?
    @State private var editDraftText: String = ""
    /// Plaintext exists only while the unlocked password category is visible.
    /// It is view-local so locking, switching category, or closing the panel
    /// can discard every revealed value in one operation.
    @State private var revealedSecretTexts: [UUID: String] = [:]
    /// Drives the fade/scale-out that plays when an edit finishes, before the
    /// panel actually collapses. Without it the whole expanded preview vanishes
    /// in a single frame, which reads as a crash rather than a dismissal.
    @State private var editorClosing = false
    /// Code highlighting and image decoding are the expensive row types. Keep
    /// only a bounded prefix in SwiftUI's view tree, extending it when the last
    /// rendered item becomes visible. The complete ordered result remains in
    /// `entries` for search, shortcuts and keyboard navigation.
    @State private var visibleEntryLimit = Int.max
    @AppStorage(AppPreferences.showsScrollIndicatorsKey) private var showsScrollIndicators = true

    fileprivate init(
        store: ClipboardHistoryStore,
        lockStore: AppLockStore,
        detailPresentation: ClipboardDetailPresentation,
        onDone: @escaping () -> Void,
        onContentChange: @escaping (CGFloat, CGFloat) -> Void,
        onDetailEntry: @escaping (ClipboardEntry?) -> Void,
        onAddToMemes: @escaping (ClipboardEntry) -> Void,
        onTogglePin: @escaping (ClipboardEntry) -> Void
    ) {
        self.store = store
        self.lockStore = lockStore
        _detailPresentation = ObservedObject(wrappedValue: detailPresentation)
        self.onDone = onDone
        self.onContentChange = onContentChange
        self.onDetailEntry = onDetailEntry
        self.onAddToMemes = onAddToMemes
        self.onTogglePin = onTogglePin
        _visibleEntryLimit = State(initialValue: ClipboardPanelPagination.initialLimit(for: store.settings.activeCategoryKey))
    }

    private var activeKey: ClipboardCategoryKey { store.settings.activeCategoryKey }
    private var advancedOptions: ClipboardAdvancedOptions? {
        store.settings.resolvedAdvancedOptions
    }
    /// True while the active category requires unlocking. Everything downstream
    /// (`entries`, the height math, ⌘1–9, Return) reads an empty list in this
    /// state, so a locked category cannot leak rows through any path.
    private var activeGate: AppLockStore.GateState { lockStore.gateState(forCategory: activeKey) }
    private var isActiveCategoryLocked: Bool { activeGate != .open }
    private var entries: ClipboardOrderedResults {
        guard !isActiveCategoryLocked else { return .empty }
        let ordered = store.orderedEntries(
            query: query,
            key: activeKey,
            advancedOptions: advancedOptions
        )
        guard activeKey == .builtin(.password) else { return ordered }
        // Projection stays lazy: only rows/shortcuts actually read by the
        // panel receive plaintext, and the source Store models remain encrypted.
        return ordered.displayingSecrets(revealedSecretTexts)
    }
    private var visibleEntries: ClipboardOrderedResults.SubSequence {
        entries.prefix(min(visibleEntryLimit, entries.count))
    }
    private var activeSelectionID: UUID? {
        contextMenuEntryID ?? hoveredID ?? keyboardSelectedID
    }

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

                detailPointer

                detailCard
                    .offset(x: detailCardXOffset, y: detailPresentation.detailTopOffset)
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

    @ViewBuilder
    private var detailPointer: some View {
        if detailPresentation.isVisible, detailPresentation.placement != .overlay {
            let pointsRight = detailPresentation.placement == .left
            let x: CGFloat = if pointsRight {
                detailCardXOffset + detailPresentation.cardSize.width - 4
            } else {
                detailCardXOffset - 10
            }
            ClipboardDetailPointer(pointsRight: pointsRight)
                .fill(.regularMaterial)
                .frame(width: ClipboardDetailPointer.width, height: ClipboardDetailPointer.height)
                .offset(
                    x: x,
                    y: detailPresentation.detailTopOffset + detailPresentation.pointerOffsetY - ClipboardDetailPointer.height / 2
                )
        }
    }

    private var listContent: some View {
        listContentLifecycle
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSMenu.didBeginTrackingNotification
                )
            ) { _ in
                contextMenuTrackingBegan()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSMenu.didEndTrackingNotification
                )
            ) { _ in
                contextMenuTrackingEnded()
            }
            .onDisappear {
                cancelPendingPreview()
                contextMenuEntryID = nil
                contextMenuTrackingDepth = 0
                revealedSecretTexts.removeAll(keepingCapacity: false)
            }
            .sheet(isPresented: queueErrorPresented) {
                UnifiedMessagePopupContent(
                    title: L10n.text("粘贴队列"),
                    message: queueError ?? "",
                    onDismiss: { queueError = nil }
                )
                .unifiedPopupSurface()
            }
    }

    private var listContentLifecycle: some View {
        listContentSelectionObservers
            .onChange(of: store.settings.pasteQueueEntryIDs) { _, _ in
                DispatchQueue.main.async { reportContentHeight() }
            }
            .onChange(of: store.settings.enabledCategoryKeys.map(\.storageValue)) { _, _ in
                DispatchQueue.main.async { reportContentHeight() }
            }
            .onChange(of: store.settings.customCategories) { _, _ in
                validateAdvancedSourceSelection()
                DispatchQueue.main.async { reportContentHeight() }
            }
            .onChange(of: activeKey.storageValue) { _, _ in
                refreshRevealedSecrets()
                selectionAndSizeChanged(resetPage: true)
            }
            // Only the *gate* transition needs its own resize. A category switch
            // is already handled above; reacting to both fired two resizes.
            .onChange(of: activeGate) { _, _ in protectedGateChanged() }
            .onChange(of: activeKey.storageValue) { _, _ in noteProtectedActivity() }
            // Observing the revision rather than `entries` itself: SwiftUI
            // compares the old and new value of whatever it is given, and
            // comparing two copies of a long history element by element runs
            // on every clipboard capture.
            .onChange(of: store.entriesRevision) { _, _ in
                refreshRevealedSecrets()
                validateAdvancedSourceSelection()
                selectionAndSizeChanged(resetPage: false)
            }
            .onChange(of: visibleEntryLimit) { _, _ in
                DispatchQueue.main.async { reportContentHeight() }
            }
            .onChange(of: detailPresentation.isVisible) { _, visible in
                if !visible { editorClosing = false }
            }
    }

    private var listContentSelectionObservers: some View {
        listContentBase
            .onAppear {
                refreshRevealedSecrets()
                validateAdvancedSourceSelection()
                resetPagination()
                validateSelection()
                reportContentHeight()
                noteProtectedActivity()
            }
            .onChange(of: query) { _, _ in
                selectionAndSizeChanged(resetPage: true)
            }
            .onChange(of: store.settings.lastCategory) { _, _ in
                validateAdvancedSourceSelection()
                selectionAndSizeChanged(resetPage: true)
            }
            .onChange(of: store.settings.advancedModeEnabled) { _, _ in
                selectionAndSizeChanged(resetPage: true)
            }
            .onChange(of: store.settings.advancedSourceIdentifier) { _, _ in
                selectionAndSizeChanged(resetPage: true)
            }
            .onChange(of: store.settings.advancedSortField) { _, _ in
                selectionAndSizeChanged(resetPage: true)
            }
            .onChange(of: store.settings.advancedSortDirection) { _, _ in
                selectionAndSizeChanged(resetPage: true)
            }
    }

    private var listContentBase: some View {
        VStack(spacing: ClipboardPanelLayout.sectionSpacing) {
            PanelSearchField(placeholder: L10n.text("搜索剪贴板"), text: $query)
                .frame(height: ClipboardPanelLayout.headerHeight)
            categoryBar
                .frame(height: categoryBarHeight)
            if store.settings.resolvedAdvancedModeEnabled {
                advancedFilterBar
                    .frame(height: ClipboardPanelLayout.advancedFilterHeight)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isActiveCategoryLocked {
                // Fills the same slot the scrolling list would, so the VStack
                // keeps filling its frame. A fixed-height gate left the stack
                // shorter than the card, and its default centring then slid the
                // search field up and back while the height animated.
                PINGateView(lockStore: lockStore, gate: activeGate, surfaceName: title(for: activeKey))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    content(proxy: proxy)
                }
                .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
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
        }
        // Top-anchored: the search field and category bar must keep their
        // position no matter how the area below them resizes.
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(ClipboardPanelLayout.outerPadding)
        .frame(width: ClipboardPanelLayout.panelWidth)
        // A non-activating panel's search field normally owns first responder,
        // so a zero-sized SwiftUI key view never sees navigation or command
        // keys.  This bridge installs a *window-scoped* local monitor instead:
        // ordinary text still reaches the search field, while clipboard
        // actions remain available no matter which control has focus.
        .background(KeyCaptureView { event in handleKey(event) }.frame(width: 1, height: 1))
    }

    @ViewBuilder
    private var detailCard: some View {
        if let entry = detailPresentation.entry {
            SystemGlassCard {
                ClipboardDetailCard(
                    entry: entry,
                    imageURL: detailPresentation.imageURL,
                    cardSize: detailPresentation.cardSize,
                    codeHighlightTheme: store.settings.resolvedCodeHighlightTheme,
                    isEditing: editingEntryID == entry.id,
                    editText: $editDraftText
                )
            }
            .frame(
                width: detailPresentation.cardSize.width,
                height: detailPresentation.cardSize.height,
                alignment: .topLeading
            )
            // A fresh hover inserts this subtree, so the pop plays only when the
            // preview first appears — not while the pointer moves between rows
            // and the same card is merely re-sized in place.
            .modifier(DetailCardPopIn())
            // The mirror image of the pop-in: when an edit finishes, this scales
            // and fades the card out in place (the panel is still expanded) so
            // the follow-up collapse lands on an already-invisible card.
            .opacity(editorClosing ? 0 : 1)
            .scaleEffect(editorClosing ? 0.94 : 1)
        }
    }

    private var emptyTitle: String {
        switch activeKey {
        case .builtin(let category):
            switch category {
            case .image: L10n.text("没有图片记录")
            case .screenshot: L10n.text("没有截图记录")
            case .text: L10n.text("没有文本记录")
            case .code: L10n.text("没有代码记录")
            case .link: L10n.text("没有链接记录")
            case .password: L10n.text("没有密码记录")
            }
        case .custom:
            L10n.text("没有匹配的记录")
        }
    }

    private var emptySymbol: String {
        switch activeKey {
        case .builtin(let category): category.systemImage
        case .custom: "tag"
        }
    }

    private func selectionAndSizeChanged(resetPage: Bool) {
        // A query/category switch or a background list refresh must not yank
        // the detail card out from under an active edit and discard the draft.
        guard editingEntryID == nil else { return }
        if resetPage { resetPagination() }
        validateSelection()
        // A category/query change replaces the list, so a preview of the old
        // entry is invalid. Collapse it before calculating the new category's
        // height; otherwise the controller deliberately ignores a resize while
        // a detail slideout is visible.
        onDetailEntry(nil)
        DispatchQueue.main.async { reportContentHeight() }
    }

    private func refreshRevealedSecrets() {
        guard activeKey == .builtin(.password), activeGate == .open else {
            revealedSecretTexts.removeAll(keepingCapacity: false)
            return
        }
        var revealed: [UUID: String] = [:]
        for entry in store.orderedEntries(key: .builtin(.password)) where entry.isSecret {
            if let plaintext = store.plaintextForUnlockedDisplay(entry) {
                revealed[entry.id] = plaintext
            }
        }
        revealedSecretTexts = revealed
    }

    private func protectedGateChanged() {
        refreshRevealedSecrets()
        validateAdvancedSourceSelection()
        if isActiveCategoryLocked {
            // A preview retains the value it was given even after the list
            // becomes empty. Tear it down before the next frame so plaintext
            // cannot survive a re-lock in the slide-out card.
            cancelPendingPreview()
            hoveredID = nil
            keyboardSelectedID = nil
            editingEntryID = nil
            editDraftText = ""
            onDetailEntry(nil)
        }
        reportContentHeight()
    }

    /// A source can exist elsewhere in history but have no item in the active
    /// category. Reset that stale selection instead of showing an empty,
    /// unavailable choice in the native Picker.
    private func validateAdvancedSourceSelection() {
        guard let identifier = store.settings.advancedSourceIdentifier else { return }
        if identifier == ClipboardAdvancedOptions.unknownSourceIdentifier {
            if !hasUnknownSourceEntries {
                store.settings.advancedSourceIdentifier = nil
            }
            return
        }
        if !availableSourceApplications.contains(where: {
            $0.stableIdentifier == identifier
        }) {
            store.settings.advancedSourceIdentifier = nil
        }
    }

    /// Marks the unlocked session as in use while a protected category is being
    /// viewed, so the idle timing means "unused" rather than "since unlock".
    private func noteProtectedActivity() {
        guard lockStore.settings.isCategoryLocked(activeKey) else { return }
        lockStore.noteActivity()
    }

    private func reportContentHeight() {
        // One page is deliberately much taller than the panel's maximum viewport,
        // so using the rendered prefix yields the same clamped window size without
        // scanning every long code value solely for height arithmetic.
        guard !isActiveCategoryLocked else {
            onContentChange(ClipboardPanelLayout.lockedStateHeight, categoryBarHeight)
            return
        }
        onContentChange(
            ClipboardPanelLayout.contentHeight(for: visibleEntries, key: activeKey),
            categoryBarHeight
        )
    }

    private func resetPagination() {
        visibleEntryLimit = ClipboardPanelPagination.initialLimit(for: activeKey)
    }

    /// `total` is passed in rather than read from `entries`: this runs from
    /// every cell's `onAppear`, and resolving the ordered list again per cell
    /// made a page of rows quadratic in the category size.
    private func loadNextPageIfNeeded(atIndex index: Int, total: Int) {
        let visibleCount = min(visibleEntryLimit, total)
        guard visibleCount < total else { return }
        // Grow when a cell within the prefetch window near the tail appears,
        // not only the very last one, so the next page is ready before it is
        // scrolled to.
        guard index >= visibleCount - ClipboardPanelPagination.prefetchDistance(for: activeKey) else { return }
        visibleEntryLimit = ClipboardPanelPagination.nextLimit(
            current: visibleEntryLimit,
            total: total,
            key: activeKey
        )
    }

    private func ensurePageContains(index: Int) {
        guard index >= visibleEntryLimit else { return }
        let pageSize = ClipboardPanelPagination.pageSize(for: activeKey)
        visibleEntryLimit = min(entries.count, ((index / pageSize) + 1) * pageSize)
    }

    /// macOS 27's default accessibility action asks LazyVStack's ForEach for
    /// collection offsets while the paged prefix is changing and traps inside
    /// `ForEachState.item(at:offset:)`. Keep VoiceOver/AX scrolling functional,
    /// but advance it through the same bounded pages as pointer scrolling and
    /// wait until the current accessibility traversal has returned before
    /// mutating SwiftUI state or issuing ScrollViewProxy work.
    private func scheduleAccessibilityScroll(
        _ edge: Edge,
        proxy: ScrollViewProxy
    ) {
        DispatchQueue.main.async {
            let all = entries
            guard !all.isEmpty else { return }

            switch edge {
            case .top:
                proxy.scrollTo(all[all.startIndex].id, anchor: .top)
            case .bottom:
                let currentLimit = min(visibleEntryLimit, all.count)
                let nextLimit = ClipboardPanelPagination.nextLimit(
                    current: currentLimit,
                    total: all.count,
                    key: activeKey
                )
                if nextLimit != visibleEntryLimit {
                    visibleEntryLimit = nextLimit
                }
                let targetID = all[all.index(all.startIndex, offsetBy: nextLimit - 1)].id
                DispatchQueue.main.async {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            case .leading, .trailing:
                break
            }
        }
    }

    private func title(for key: ClipboardCategoryKey) -> String {
        ClipboardCategoryBarMetrics.title(for: key, settings: store.settings)
    }

    private var categoryRows: [[ClipboardCategoryKey]] {
        ClipboardCategoryBarMetrics.rows(
            settings: store.settings,
            queueCount: store.pasteQueueCount
        )
    }

    private var categoryBarHeight: CGFloat {
        ClipboardCategoryBarMetrics.height(
            settings: store.settings,
            queueCount: store.pasteQueueCount
        )
    }

    private func selectCategory(_ key: ClipboardCategoryKey) {
        if key == .builtin(.password) || lockStore.settings.isCategoryLocked(key) {
            lockStore.prepareVaultAccess()
        }
        store.settings.activeCategoryKey = key
    }

    private var categoryBar: some View {
        VStack(alignment: .leading, spacing: ClipboardCategoryBarMetrics.lineSpacing) {
            ForEach(Array(categoryRows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.storageValue) { key in
                        Toggle(
                            title(for: key),
                            isOn: Binding(
                                get: { activeKey == key },
                                set: { selected in
                                    if selected { selectCategory(key) }
                                }
                            )
                        )
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                    if rowIndex == categoryRows.count - 1 {
                        Spacer(minLength: 6)
                        ControlGroup {
                            Button {
                                pasteNextQueued()
                            } label: {
                                if store.pasteQueueCount > 0 {
                                    Label(
                                        "\(store.pasteQueueCount)",
                                        systemImage: "list.number"
                                    )
                                    .monospacedDigit()
                                } else {
                                    Image(systemName: "list.number")
                                }
                            }
                            .disabled(store.pasteQueueCount == 0)
                            .help(L10n.text("粘贴队列中的下一项"))
                            .accessibilityLabel(L10n.text("粘贴队列"))
                            .accessibilityValue(
                                L10n.format(
                                    "粘贴队列项目数格式",
                                    store.pasteQueueCount
                                )
                            )
                            .contextMenu {
                                Button(
                                    L10n.text("清空粘贴队列"),
                                    role: .destructive
                                ) {
                                    store.clearPasteQueue()
                                }
                                .disabled(store.pasteQueueCount == 0)
                            }

                            Toggle(
                                isOn: Binding(
                                    get: {
                                        store.settings.resolvedAdvancedModeEnabled
                                    },
                                    set: {
                                        store.settings.advancedModeEnabled = $0
                                    }
                                )
                            ) {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                            .toggleStyle(.button)
                            .help(L10n.text("高级筛选与排序"))
                            .accessibilityLabel(L10n.text("高级筛选与排序"))
                            .accessibilityValue(
                                L10n.text(
                                    store.settings.resolvedAdvancedModeEnabled
                                        ? "已开启"
                                        : "已关闭"
                                )
                            )
                        }
                        .controlSize(.small)
                        .frame(height: ClipboardPanelLayout.segmentedHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var availableSourceApplications: [ClipboardSourceApplication] {
        store.sourceApplicationsForFiltering(
            key: activeKey,
            includeSecrets: mayExposeSecretSources
        )
    }

    private var hasUnknownSourceEntries: Bool {
        store.hasUnknownSourceForFiltering(
            key: activeKey,
            includeSecrets: mayExposeSecretSources
        )
    }

    private var mayExposeSecretSources: Bool {
        activeKey == .builtin(.password) && activeGate == .open
    }

    private var advancedFilterBar: some View {
        HStack(spacing: 6) {
            Picker(
                L10n.text("来源"),
                selection: Binding(
                    get: { store.settings.advancedSourceIdentifier },
                    set: { store.settings.advancedSourceIdentifier = $0 }
                )
            ) {
                Text(L10n.text("全部来源")).tag(nil as String?)
                if hasUnknownSourceEntries {
                    Text(L10n.text("未知来源"))
                        .tag(ClipboardAdvancedOptions.unknownSourceIdentifier as String?)
                }
                ForEach(availableSourceApplications) { application in
                    Text(application.displayName)
                        .tag(application.stableIdentifier as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(L10n.text("按来源应用筛选"))
            .accessibilityLabel(L10n.text("来源"))

            Picker(
                L10n.text("排序依据"),
                selection: Binding(
                    get: { store.settings.resolvedAdvancedSortField },
                    set: { store.settings.selectAdvancedSortField($0) }
                )
            ) {
                ForEach(ClipboardAdvancedSortField.allCases, id: \.self) { field in
                    Text(sortPickerTitle(for: field)).tag(field)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(L10n.text("排序依据"))
            .accessibilityLabel(L10n.text("排序依据"))
            .accessibilityValue(store.settings.resolvedAdvancedSortDirection.displayName)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sortPickerTitle(for field: ClipboardAdvancedSortField) -> String {
        guard field == store.settings.resolvedAdvancedSortField else {
            return field.displayName
        }
        let arrow = store.settings.resolvedAdvancedSortDirection == .ascending
            ? "↑"
            : "↓"
        return "\(field.displayName) \(arrow)"
    }

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        // Resolved once per pass. `entries` is not free — for the password
        // category it projects the revealed text over the whole list — and it
        // was previously reached again from every row's `onAppear`.
        let all = entries
        // Materialize only the bounded visible page. Passing the custom lazy
        // RandomAccessCollection directly into ForEach lets macOS 27's
        // accessibility scroll path hold offsets across separate collection
        // evaluations; it can then trap inside ForEachState.item(at:offset:).
        // A stable Array costs only a few dozen KiB at the 300-row maximum and
        // contains deferred metadata, never decoded text bodies.
        let rows = Array(IndexedElements(
            base: all.prefix(min(visibleEntryLimit, all.count))
        ))
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
                ForEach(rows) { row in
                    let index = row.offset
                    let entry = row.element
                    ImageEntryCell(
                        entry: entry,
                        index: index,
                        imageURL: store.imageURL(for: entry),
                        isSelected: activeSelectionID == entry.id,
                        onTogglePin: { onTogglePin(entry) },
                        onToggleClipboardPin: { store.togglePinned(id: entry.id) }
                    )
                    .equatable()
                    .id(entry.id)
                    .onTapGesture { copy(entry) }
                    .overlay {
                        EntryHoverTrackingOverlay { updateHover($0, entry: entry) }
                    }
                    .contextMenu { entryMenu(entry) }
                    .onAppear {
                        // Accessibility can synchronously enumerate every
                        // visible ForEach item while performing a scroll
                        // action. Growing the prefix inside that enumeration
                        // changes ForEach's bounds mid-read and traps in
                        // ForEachState.item(at:offset:). Advance on the next
                        // main-loop turn so the current traversal finishes
                        // against one stable collection snapshot.
                        DispatchQueue.main.async {
                            loadNextPageIfNeeded(atIndex: index, total: all.count)
                        }
                    }
                }
            }
            .accessibilityScrollAction { edge in
                scheduleAccessibilityScroll(edge, proxy: proxy)
            }
        default:
            LazyVStack(spacing: ClipboardPanelLayout.listSpacing) {
                ForEach(rows) { row in
                    let index = row.offset
                    let entry = row.element
                    VStack(spacing: 0) {
                        if entry.kind == .image {
                            CompactImageEntryRow(
                                entry: entry,
                                index: index,
                                imageURL: store.imageURL(for: entry),
                                isSelected: activeSelectionID == entry.id,
                                onTogglePin: { onTogglePin(entry) },
                                onToggleClipboardPin: { store.togglePinned(id: entry.id) }
                            )
                            .equatable()
                        } else if activeKey == .builtin(.code) {
                            CodeEntryRow(
                                entry: entry,
                                index: index,
                                isSelected: activeSelectionID == entry.id,
                                codeHighlightTheme: store.settings.resolvedCodeHighlightTheme,
                                onTogglePin: { onTogglePin(entry) },
                                onToggleClipboardPin: { store.togglePinned(id: entry.id) }
                            )
                            .equatable()
                        } else {
                            TextEntryRow(
                                entry: entry,
                                index: index,
                                isSelected: activeSelectionID == entry.id,
                                onTogglePin: { onTogglePin(entry) },
                                onToggleClipboardPin: { store.togglePinned(id: entry.id) }
                            )
                            .equatable()
                        }
                        if activeKey == .builtin(.code), index < rows.count - 1 {
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
                    .onAppear {
                        DispatchQueue.main.async {
                            loadNextPageIfNeeded(atIndex: index, total: all.count)
                        }
                    }
                }
            }
            .accessibilityRepresentation {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Text(accessibilityRowLabel(for: row.element))
                            .accessibilityIdentifier(row.element.id.uuidString)
                    }
                }
                .accessibilityScrollAction { edge in
                    scheduleAccessibilityScroll(edge, proxy: proxy)
                }
            }
        }
    }

    private func accessibilityRowLabel(for entry: ClipboardEntry) -> String {
        if entry.isSecret { return L10n.text("已隐藏的密码") }
        guard entry.kind == .text, let text = entry.text else {
            return L10n.text("图片")
        }
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else {
            return L10n.text("空白文字")
        }
        return String(text[start...].prefix(300))
            .replacingOccurrences(of: "\n", with: " ")
    }

    @ViewBuilder
    private func entryMenu(_ entry: ClipboardEntry) -> some View {
        if entry.kind == .image {
            Button {
                onAddToMemes(entry)
            } label: {
                Label(L10n.text("添加到表情包"), systemImage: "photo.badge.plus")
            }
            Divider()
        }
        if entry.kind == .text, !entry.isSecret {
            Button(L10n.text("编辑")) { beginEditing(entry) }
        }
        Menu {
            Button {
                store.setManualCategory(id: entry.id, key: nil)
            } label: {
                categoryMenuLabel(
                    title: L10n.text("自动分类"),
                    selected: entry.manualCategoryKey == nil
                )
            }
            Divider()
            ForEach(manualCategoryTargets(for: entry), id: \.storageValue) { key in
                Button {
                    if store.setManualCategory(id: entry.id, key: key) {
                        refreshRevealedSecrets()
                    }
                } label: {
                    categoryMenuLabel(
                        title: title(for: key),
                        selected: entry.manualCategoryKey == key
                    )
                }
            }
        } label: {
            Label(L10n.text("手动分类"), systemImage: "folder")
        }
        // Context-menu content is created lazily for the row that received the
        // secondary click. This top-level item appears with the root menu, so
        // it captures the exact row even if the manual-category submenu is
        // never opened.
        .onAppear { pinContextMenuSelection(to: entry) }
        Divider()
        if let position = store.pasteQueuePosition(of: entry.id) {
            Button {
                store.removeFromPasteQueue(id: entry.id)
            } label: {
                Label(
                    L10n.format("从粘贴队列移除格式", position),
                    systemImage: "text.badge.minus"
                )
            }
        } else {
            Button {
                enqueue(entry)
            } label: {
                Label(L10n.text("加入粘贴队列"), systemImage: "text.badge.plus")
            }
        }
        Divider()
        Button(L10n.text(entry.isPinned ? "取消置顶" : "置顶")) { store.togglePinned(id: entry.id) }
        Button(L10n.text(entry.isDesktopPinned == true ? "取消桌面固定" : "固定到桌面")) { onTogglePin(entry) }
        Button(L10n.text("删除"), role: .destructive) { delete(entry) }
    }

    private func manualCategoryTargets(for entry: ClipboardEntry) -> [ClipboardCategoryKey] {
        store.settings.enabledCategoryKeys.filter { entry.supportsManualCategory($0) }
    }

    @ViewBuilder
    private func categoryMenuLabel(title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func validateSelection() {
        let ids = Set(entries.lazy.map(\.id))
        if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
        if let keyboardSelectedID, !ids.contains(keyboardSelectedID) { self.keyboardSelectedID = nil }
    }

    private func updateHover(_ isHovered: Bool, entry: ClipboardEntry) {
        // The pointer drifting on or off some other row mid-edit — or during the
        // brief close animation right after an edit — must not touch the
        // preview: `beginEditing` already moved this entry's selection out of
        // `hoveredID`, so no exit timer targeting it is pending here to cancel.
        guard editingEntryID == nil, !editorClosing, contextMenuEntryID == nil else { return }
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

    private func contextMenuTrackingBegan() {
        contextMenuTrackingDepth += 1
        if contextMenuEntryID == nil {
            contextMenuEntryID = hoveredID ?? keyboardSelectedID
        }
        // An exit scheduled just before AppKit began tracking must not clear
        // the frozen row while the pointer moves from that row into the menu.
        cancelPendingPreview()
    }

    private func pinContextMenuSelection(to entry: ClipboardEntry) {
        contextMenuEntryID = entry.id
        hoveredID = entry.id
        keyboardSelectedID = nil
        keyboardSelection = false
        cancelPendingPreview()
    }

    private func contextMenuTrackingEnded() {
        contextMenuTrackingDepth = max(0, contextMenuTrackingDepth - 1)
        guard contextMenuTrackingDepth == 0 else { return }
        contextMenuEntryID = nil
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
        // Using protected content is what the "N minutes unused" timing counts;
        // without this the idle window ran from the unlock instant regardless
        // of how actively the user was working with the category.
        if entry.isSecret || lockStore.settings.isCategoryLocked(activeKey) {
            lockStore.noteActivity()
        }
        _ = store.copyToPasteboard(entry, autoPaste: store.settings.autoPaste)
        onDone()
    }

    private func enqueue(_ entry: ClipboardEntry) {
        do {
            _ = try store.enqueueForPaste(id: entry.id)
        } catch {
            queueError = error.localizedDescription
        }
    }

    private var queueErrorPresented: Binding<Bool> {
        Binding(
            get: { queueError != nil },
            set: { isPresented in
                if !isPresented { queueError = nil }
            }
        )
    }

    private func pasteNextQueued() {
        do {
            let passwordUnlocked =
                lockStore.gateState(forCategory: .builtin(.password)) == .open
            let entry = try store.pasteNextQueued(
                autoPaste: store.settings.autoPaste,
                allowsProtectedEntries: passwordUnlocked
            )
            if entry.isSecret { lockStore.noteActivity() }
            onDone()
        } catch {
            queueError = error.localizedDescription
        }
    }

    private func delete(_ entry: ClipboardEntry) {
        store.delete(id: entry.id)
        validateSelection()
    }

    // MARK: - Editing

    /// Only non-secret text entries can be edited. Password values are revealed
    /// for reading/copying after unlock but remain immutable ciphertext in the
    /// history store.
    private func beginEditing(_ entry: ClipboardEntry) {
        guard entry.kind == .text, !entry.isSecret else { return }
        cancelPendingPreview()
        // Route the selection through the keyboard slot instead of hover, so
        // the pointer leaving this row can never trigger the hover-exit path
        // that would otherwise close the card mid-edit (see `updateHover`).
        hoveredID = nil
        keyboardSelectedID = entry.id
        editDraftText = entry.text ?? ""
        editingEntryID = entry.id
        // Force the detail card open immediately — editing shouldn't wait out
        // the normal hover dwell delay — and pin it to this exact entry even
        // if it was already showing something else.
        onDetailEntry(entry)
    }

    private func commitEditing() { finishEditing(save: true) }

    private func cancelEditing() { finishEditing(save: false) }

    /// Saving blank text would leave a pointless empty entry, so an
    /// all-whitespace draft quietly discards instead of persisting.
    ///
    /// The persist runs *before* `editingEntryID` is cleared so the
    /// `store.entries` observer stays guarded and cannot collapse the card
    /// early. Then the card is faded/scaled out in place while the panel is
    /// still expanded, and only afterwards does the panel actually collapse —
    /// so finishing an edit reads as a smooth dismissal, not a crash.
    private func finishEditing(save: Bool) {
        guard let id = editingEntryID else { return }
        if save {
            let draft = editDraftText
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.updateText(id: id, text: draft)
            }
        }
        editingEntryID = nil
        withAnimation(.easeOut(duration: 0.22)) { editorClosing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            onDetailEntry(nil)
            // Recompute the list height once collapsed: an edited code entry may
            // now occupy a different number of preview lines.
            DispatchQueue.main.async { reportContentHeight() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // The PIN gate owns the keyboard while it is up. This monitor is
        // window-wide, so without this every digit, Delete and Return would be
        // consumed here (⌫ = "delete entry", ⏎ = "copy") and never reach the PIN
        // field — which is why backspace appeared to do nothing.
        if isActiveCategoryLocked { return false }

        // While editing, only the save/cancel shortcuts are ours to intercept.
        // Everything else — letters, arrows, Delete, Return, ⌘A/C/V/X/Z — must
        // reach the TextEditor's own responder untouched, or typing, cursor
        // movement and even undo would silently stop working the moment this
        // monitor is installed on the panel's window.
        if editingEntryID != nil {
            guard event.type == .keyDown else { return false }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" {
                commitEditing()
                return true
            }
            if event.keyCode == 53 {
                cancelEditing()
                return true
            }
            return false
        }

        if event.type == .flagsChanged {
            if !flags.contains(.command), let copyID = pendingCommandCopyID {
                pendingCommandCopyID = nil
                if let entry = entries.first(where: { $0.id == copyID }) {
                    copy(entry)
                }
                return true
            }
            return false
        }

        if flags.contains(.command), let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
            guard number <= entries.count else { return true }
            let entry = entries[number - 1]
            if event.type == .keyDown {
                keyboardSelectedID = entry.id
                hoveredID = nil
                pendingCommandCopyID = entry.id
            }
            // Consume keyUp or other events for this shortcut so it doesn't trigger system beep
            return true
        }

        // Other shortcuts should only trigger on keyDown
        guard event.type == .keyDown else { return false }


        // ⌘E enters editing for the active text entry. Images have no text
        // body, so the shortcut simply falls through and does nothing for them.
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "e",
           let entry = entries.first(where: { $0.id == activeSelectionID }),
           entry.kind == .text, !entry.isSecret {
            beginEditing(entry)
            return true
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p", let selectedID = activeSelectionID {
            store.togglePinned(id: selectedID)
            return true
        }
        if flags.contains(.command), event.keyCode == 36,
           let entry = entries.first(where: { $0.id == activeSelectionID }) {
            enqueue(entry)
            return true
        }
        if flags.contains(.shift), event.keyCode == 36 {
            pasteNextQueued()
            return true
        }
        // ⌥P mirrors the "固定到桌面" button/menu, going through the same callback
        // so the desktop note is created and the history panel closes.
        if flags.contains(.option), event.charactersIgnoringModifiers?.lowercased() == "p",
           let entry = entries.first(where: { $0.id == activeSelectionID }) {
            onTogglePin(entry)
            return true
        }
        let columns = (activeKey == .builtin(.image) || activeKey == .builtin(.screenshot))
            ? ClipboardPanelLayout.imageColumns
            : 1
            
        // Clear pending copy if user performs any other keyboard navigation
        pendingCommandCopyID = nil
        
        switch event.keyCode {
        case 36, 76:
            guard let entry = entries.first(where: { $0.id == activeSelectionID }) else { return true }
            copy(entry)
            return true
        case 51, 117:
            // The mouse hovering a row always targets that row for deletion.
            if let hoveredID, let entry = entries.first(where: { $0.id == hoveredID }) {
                delete(entry)
                return true
            }
            // Otherwise, when the search box holds text, Delete must edit the
            // query — let the event fall through to the field instead of
            // removing an entry the pointer isn't even on.
            if !query.isEmpty { return false }
            // Empty search and nothing hovered: fall back to the keyboard
            // selection so arrow-key navigation can still delete.
            if let entry = entries.first(where: { $0.id == keyboardSelectedID }) { delete(entry) }
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
        ensurePageContains(index: nextIndex)
        keyboardSelection = true
        hoveredID = nil
        keyboardSelectedID = entries[nextIndex].id
    }
}

// MARK: - Rows

/// Every row is `Equatable` over its *data* (deliberately ignoring the action
/// closures, which are recreated each parent pass but capture equal values) and
/// installed with `.equatable()`. Without this, a hover moving between two rows
/// re-evaluated every row body in the list — the direct cause of the highlight
/// lagging behind the pointer even with a dozen entries.
private struct TextEntryRow: View, Equatable {
    nonisolated static func == (lhs: TextEntryRow, rhs: TextEntryRow) -> Bool {
        lhs.entry == rhs.entry && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
    }

    let entry: ClipboardEntry
    let index: Int?
    let isSelected: Bool
    let onTogglePin: () -> Void
    let onToggleClipboardPin: () -> Void

    /// One truncated line displays only a screenful of characters; running
    /// `replacingOccurrences` over an entire large clipboard text on every row
    /// render was a per-frame scroll cost. The prefix is far beyond what
    /// `lineLimit(1)` can show, so the rendering is unchanged.
    private var previewLine: String {
        guard entry.kind == .text, let text = entry.text else { return entry.previewText }
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return L10n.text("空白文字") }
        return String(text[start...].prefix(300)).replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(previewLine)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
            if isSelected {
                Button(action: onToggleClipboardPin) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(L10n.text(entry.isPinned ? "取消剪切板内固定" : "固定到剪切板"))
                ClipboardPinButton(entry: entry, isSelected: true, action: onTogglePin)
            } else {
                // Unselected: the desktop-pin badge leads and the copy shortcut
                // trails, so a pinned item's persistent indicator sits left of
                // the ⌘-number. A hovered row is always `isSelected` (the panel
                // owns hover), so this branch only ever runs for un-hovered rows.
                if entry.isDesktopPinned == true {
                    ClipboardPinButton(entry: entry, isSelected: false, action: onTogglePin)
                }
                if let index, index < 9 {
                    Text("⌘ \(index + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(entry.isPinned ? Color.primary : Color.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
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
    }
}

/// Custom smart categories can mix text and images. Keep image rows at the
/// same compact list height while retaining a real thumbnail; falling back to
/// the word “图片” would make source/type rules visually lossy.
private struct CompactImageEntryRow: View, Equatable {
    nonisolated static func == (lhs: CompactImageEntryRow, rhs: CompactImageEntryRow) -> Bool {
        lhs.entry == rhs.entry
            && lhs.index == rhs.index
            && lhs.imageURL == rhs.imageURL
            && lhs.isSelected == rhs.isSelected
    }

    let entry: ClipboardEntry
    let index: Int?
    let imageURL: URL?
    let isSelected: Bool
    let onTogglePin: () -> Void
    let onToggleClipboardPin: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quinary)
                if let imageURL {
                    ThumbnailImageView(
                        url: imageURL,
                        targetPoints: 22,
                        contentIdentity: entry.contentHash
                    )
                    .padding(1)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(entry.text?.isEmpty == false ? entry.text! : L10n.text("图片"))
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)

            if isSelected {
                Button(action: onToggleClipboardPin) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(L10n.text(entry.isPinned ? "取消剪切板内固定" : "固定到剪切板"))
                ClipboardPinButton(entry: entry, isSelected: true, action: onTogglePin)
            } else {
                if entry.isDesktopPinned == true {
                    ClipboardPinButton(entry: entry, isSelected: false, action: onTogglePin)
                }
                if let index, index < 9 {
                    Text("⌘ \(index + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(entry.isPinned ? Color.primary : Color.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardPanelLayout.textRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
    }
}

private struct CodeEntryRow: View, Equatable {
    nonisolated static func == (lhs: CodeEntryRow, rhs: CodeEntryRow) -> Bool {
        lhs.entry == rhs.entry
            && lhs.index == rhs.index
            && lhs.isSelected == rhs.isSelected
            && lhs.codeHighlightTheme == rhs.codeHighlightTheme
    }

    let entry: ClipboardEntry
    let index: Int?
    let isSelected: Bool
    let codeHighlightTheme: CodeHighlightTheme
    let onTogglePin: () -> Void
    let onToggleClipboardPin: () -> Void

    var body: some View {
        // One lazy scan supplies both the preview text and the row height;
        // the previous two separate computed properties each split the text.
        let previewLines = ClipboardPanelLayout.codePreviewLines(entry.text)
        return HStack(alignment: .center, spacing: 6) {
            Text(CodeHighlighter.highlight(previewLines.joined(separator: "\n"), theme: codeHighlightTheme))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(ClipboardPanelLayout.codePreviewMaxLines)
                .lineSpacing(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
            if isSelected {
                Button(action: onToggleClipboardPin) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(L10n.text(entry.isPinned ? "取消剪切板内固定" : "固定到剪切板"))
                ClipboardPinButton(entry: entry, isSelected: true, action: onTogglePin)
            } else {
                // Unselected: desktop-pin badge leads, ⌘-number trails. A hovered
                // row is always `isSelected`, so this branch is un-hovered only.
                if entry.isDesktopPinned == true {
                    ClipboardPinButton(entry: entry, isSelected: false, action: onTogglePin)
                }
                if let index, index < 9 {
                    Text("⌘ \(index + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(entry.isPinned ? Color.primary : Color.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardPanelLayout.codeRowHeight(lineCount: previewLines.count), alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
    }
}

private struct ImageEntryCell: View, Equatable {
    nonisolated static func == (lhs: ImageEntryCell, rhs: ImageEntryCell) -> Bool {
        lhs.entry == rhs.entry
            && lhs.index == rhs.index
            && lhs.imageURL == rhs.imageURL
            && lhs.isSelected == rhs.isSelected
    }

    let entry: ClipboardEntry
    let index: Int?
    let imageURL: URL?
    let isSelected: Bool
    let onTogglePin: () -> Void
    let onToggleClipboardPin: () -> Void

    private var side: CGFloat { ClipboardPanelLayout.imageCellSide }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
            if let imageURL {
                ThumbnailImageView(url: imageURL, targetPoints: side, contentIdentity: entry.contentHash)
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
            HStack(spacing: 4) {
                if isSelected {
                    Button(action: onToggleClipboardPin) {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(0.4)))
                    .help(L10n.text(entry.isPinned ? "取消剪切板内固定" : "固定到剪切板"))
                    ClipboardPinButton(entry: entry, isSelected: true, action: onTogglePin)
                        .background(Circle().fill(.black.opacity(0.4)))
                } else {
                    // Unselected: desktop-pin badge leads, ⌘-number trails. A
                    // hovered cell is always `isSelected`, so this is un-hovered.
                    if entry.isDesktopPinned == true {
                        ClipboardPinButton(entry: entry, isSelected: true, action: onTogglePin)
                            .background(Circle().fill(.black.opacity(0.4)))
                    }
                    if let index, index < 9 {
                        Text("⌘ \(index + 1)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(entry.isPinned ? Color.primary : Color.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .frame(minWidth: 28)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.5)))
                    }
                }
            }
            .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
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
        .help(L10n.text(entry.isDesktopPinned == true ? "取消桌面固定" : "固定到桌面"))
        .accessibilityLabel(L10n.text(entry.isDesktopPinned == true ? "取消桌面固定" : "固定到桌面"))
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
        // `updateNSView` runs inside SwiftUI's render transaction. Calling the
        // callback synchronously from here mutates `hoveredID` while the view
        // graph is updating, which can leave both hover and button gestures in
        // an undefined state. Re-evaluate on the next main-loop turn instead.
        nsView.scheduleHoverRefresh()
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var pendingRefresh: DispatchWorkItem?
        private var isInside = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                pendingRefresh?.cancel()
                pendingRefresh = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

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
            // AppKit may request tracking-area updates while SwiftUI is still
            // installing this representable. Keep that lifecycle callback out
            // of the active SwiftUI update transaction as well.
            scheduleHoverRefresh()
        }

        override func mouseEntered(with event: NSEvent) {
            // AppKit can synthesize enter/exit pairs while the hosting view
            // changes geometry. Use the actual pointer position instead.
            scheduleHoverRefresh()
        }

        override func mouseExited(with event: NSEvent) {
            scheduleHoverRefresh()
        }

        override func mouseMoved(with event: NSEvent) {
            scheduleHoverRefresh()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Tracking must never consume clicks, context menus, scrolling, or
            // the desktop-pin control placed in the same row.
            nil
        }

        /// Coalesce layout callbacks and high-frequency mouse movement into one
        /// state evaluation on the next main-loop turn. Besides avoiding
        /// SwiftUI re-entrancy, this prevents a row rebuild from queuing a
        /// cascade of stale enter/exit callbacks.
        func scheduleHoverRefresh() {
            guard pendingRefresh == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingRefresh = nil
                self.refreshHoverState()
            }
            pendingRefresh = work
            DispatchQueue.main.async(execute: work)
        }

        private func refreshHoverState() {
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

        override func keyUp(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyUp(with: event)
        }

        override func flagsChanged(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.flagsChanged(with: event)
        }

        /// Keep command/navigation routing in the panel even while the search
        /// field is first responder.  Limiting the monitor to this exact
        /// window is important: the app's global hotkeys and every other
        /// window retain their normal responder-chain behavior.
        private func installKeyEventMonitor() {
            guard keyEventMonitor == nil, window != nil else { return }
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      window.isVisible else {
                    return event
                }
                // While an input method is composing (the search field's field
                // editor holds marked text), every keystroke belongs to the IME:
                // Delete edits the in-progress reading, arrows move the candidate
                // list, Return/Escape commit or cancel. Intercepting any of these
                // would strand a composition the user cannot finish or erase, so
                // pass them straight through to the input context.
                if window.hasMarkedTextInFieldEditor { return event }
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

private extension NSWindow {
    /// True while an input method is composing marked (underlined) text in the
    /// window's field editor — the transient state before a reading commits.
    /// Editing a focused text field makes that field editor (an `NSTextView`)
    /// the first responder, so its `hasMarkedText()` is the authoritative signal.
    var hasMarkedTextInFieldEditor: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}
