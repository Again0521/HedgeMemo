import AppKit
import MemeMemoCore
import SwiftUI

/// Hover detail is deliberately presentation state of the *same* floating
/// window as the clipboard list.  A second non-key NSPanel renders the system
/// material in its inactive appearance, which is visibly gray and can never
/// match the active list.  Maccy keeps this slideout in one hosting hierarchy;
/// do the same here.
@MainActor
private final class ClipboardDetailPresentation: ObservableObject {
    @Published var entry: ClipboardEntry?
    @Published var imageURL: URL?
    @Published var cardSize: NSSize = .zero
    @Published var placement: Placement = .right
    @Published var mainTopOffset: CGFloat = 0
    @Published var mainHeight: CGFloat = 0
    @Published var detailTopOffset: CGFloat = 0

    enum Placement {
        case left
        case right
    }

    var isVisible: Bool { entry != nil }

    func show(
        entry: ClipboardEntry,
        imageURL: URL?,
        cardSize: NSSize,
        placement: Placement,
        mainTopOffset: CGFloat,
        mainHeight: CGFloat,
        detailTopOffset: CGFloat
    ) {
        self.entry = entry
        self.imageURL = imageURL
        self.cardSize = cardSize
        self.placement = placement
        self.mainTopOffset = mainTopOffset
        self.mainHeight = mainHeight
        self.detailTopOffset = detailTopOffset
    }

    func hide() {
        entry = nil
        imageURL = nil
        cardSize = .zero
        mainTopOffset = 0
        mainHeight = 0
        detailTopOffset = 0
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
    /// The main list's rect in screen coordinates — the single source of truth.
    /// The window may grow to also hold the detail card, but the main surface
    /// must keep exactly this screen position, so hovering never moves the list.
    private var mainScreenFrame: NSRect = .zero
    private let detailPresentation = ClipboardDetailPresentation()
    private let panelInset: CGFloat = 18

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
                self?.resize(contentHeight: contentHeight, animate: true)
            },
            onDetailEntry: { [weak self] entry in
                DispatchQueue.main.async { self?.updateDetail(entry: entry) }
            },
            onAddToMemes: { [weak self] entry in
                self?.addToMemes(entry)
            },
            onTogglePin: { [weak self] entry in
                self?.pinnedWindows.toggle(entry)
            }
        )
        if let mainSurface {
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
        // Keep the one native NSPanel shadow.  This is Maccy's shadow path;
        // custom SwiftUI shadows and hand-drawn outlines caused the irregular
        // dark edges reported around both the preview and clipboard.
        panel.hasShadow = true
        mainSurface = panel.contentView

        return panel
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedPanel = notification.object as? NSPanel, movedPanel === panel else { return }
        // A user drag changes the true anchor.  Previously `mainScreenFrame`
        // was left at the old opening location, so the first hover rebuilt the
        // preview against stale coordinates and snapped the clipboard back.
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
        // SwiftUI can report the same measured content size again after the
        // user starts hovering. Do not tear down a visible detail card for a
        // no-op measurement; that caused a preview to flicker or disappear.
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
        panel.setFrame(frame, display: true, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        mainScreenFrame = frame
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

    /// Displays the detail beside the list inside the existing hosting view.
    /// This is intentionally a single key NSPanel: the system glass is then
    /// composited once, so the preview and clipboard cannot diverge into active
    /// and inactive (gray) materials.
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
        let size = ClipboardDetailLayout.cardSize(
            for: entry,
            imageURL: imageURL,
            availableHeight: visibleFrame.height - panelInset * 2,
            availableWidth: max(leftAvailable, rightAvailable)
        )

        let placeLeft = leftAvailable >= size.width || leftAvailable >= rightAvailable
        // Align the preview with the hovered row rather than the panel's top.
        // The pointer is on that row after the two-second dwell, so centering
        // the card on it provides a stable, nearby relationship for both short
        // and tall previews.
        let mouseY = NSEvent.mouseLocation.y
        let detailY = min(
            max(mouseY - size.height / 2, visibleFrame.minY + inset),
            visibleFrame.maxY - size.height - inset
        )
        let hostTop = max(mainFrame.maxY, detailY + size.height)
        let hostBottom = min(mainFrame.minY, detailY)
        let hostHeight = hostTop - hostBottom
        var hostFrame = NSRect(
            x: placeLeft ? mainFrame.minX - size.width - cardGap : mainFrame.minX,
            y: hostBottom,
            width: mainFrame.width + size.width + cardGap,
            height: hostHeight
        )
        // Preserve the list's own screen position.  At a side edge the card is
        // reduced before this point, so no clamping may shift the list under
        // the pointer.
        if hostFrame.minX < visibleFrame.minX + inset {
            hostFrame.origin.x = visibleFrame.minX + inset
        }
        if hostFrame.maxX > visibleFrame.maxX - inset {
            hostFrame.origin.x = visibleFrame.maxX - inset - hostFrame.width
        }
        panel.setFrame(hostFrame, display: true, animate: false)
        detailPresentation.show(
            entry: entry,
            imageURL: imageURL,
            cardSize: size,
            placement: placeLeft ? .left : .right,
            mainTopOffset: hostTop - mainFrame.maxY,
            mainHeight: mainFrame.height,
            detailTopOffset: hostTop - detailY - size.height
        )
        mainScreenFrame = mainFrame
    }

    private func hideDetail() {
        detailEntryID = nil
        detailPresentation.hide()
        guard let panel, !mainScreenFrame.isEmpty else { return }
        panel.setFrame(mainScreenFrame, display: true, animate: false)
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
    }

    private func stopClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
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
    /// and both surfaces share one material and appearance state.
    func runLayoutSelfCheck(completion: @escaping (Bool, String) -> Void) {
        show()
        guard let panel, let screen = panel.screen ?? NSScreen.main else {
            completion(false, "self-check: panel or screen missing")
            return
        }
        let visible = screen.visibleFrame
        // Bottom of the screen, like invoking the hotkey with the mouse there.
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 12))
        mainScreenFrame = panel.frame
        // Force maximum growth, exactly what switching to a dense category does.
        resize(contentHeight: 10_000, animate: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let mainBeforeHovers = self.mainScreenFrame
            // Hover two entries with very different card sizes.
            self.updateDetail(entry: ClipboardEntry(kind: .text, text: "自检条目", contentHash: "self-check-small"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.updateDetail(entry: ClipboardEntry(
                    kind: .text,
                    text: Array(repeating: "自检长内容行", count: 30).joined(separator: "\n"),
                    contentHash: "self-check-large"
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.evaluateSelfCheck(visible: visible, mainBeforeHovers: mainBeforeHovers, completion: completion)
                }
            }
        }
    }

    private func evaluateSelfCheck(
        visible: NSRect,
        mainBeforeHovers: NSRect,
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

        let mainBounds = mainSurface?.bounds ?? .zero
        report.append("singleHostBounds=\(mainBounds)")
        // The one host intentionally contains both cards. Its bounds must be
        // large enough for the main list, but it is no longer expected to equal
        // the list's frame while a preview is visible.
        if mainBounds.height + 1 < mainScreenFrame.height || mainBounds.width + 1 < mainScreenFrame.width {
            failures.append("single material host is smaller than the main list")
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                detailRow("来源", entry.sourceApp ?? "未知")
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
            ScrollView([.horizontal, .vertical]) {
                Text(CodeHighlighter.highlight(entry.text ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    // Never wrap a source line just because the initial card
                    // is narrow. The controller first grows the card to fit;
                    // only truly long lines use horizontal scrolling.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(height: ClipboardDetailLayout.previewAreaHeight(cardHeight: cardSize.height))
        } else {
            ScrollView(.vertical) {
                Text(entry.text ?? entry.previewText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
}

private enum ClipboardDetailLayout {
    private static let minimumWidth: CGFloat = 360
    private static let maximumWidth: CGFloat = 640
    private static let horizontalPadding: CGFloat = 12
    private static let verticalChrome: CGFloat = 161
    // A single text line should not reserve a tall preview; only images get a
    // comfortable minimum so a thumbnail isn't cramped.
    private static let minimumPreviewHeight: CGFloat = 18
    private static let minimumImagePreviewHeight: CGFloat = 96
    private static let screenMargin: CGFloat = 24

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
            let lines = max(1, text.components(separatedBy: .newlines).count)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return min(CGFloat(lines) * lineHeight, maximumHeight)
        }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return max(lineHeight, min(ceil(bounds.height), maximumHeight))
    }

    /// Code gets just enough extra width to preserve ordinary source lines,
    /// then deliberately caps at a readable desktop-card size.  Text and image
    /// previews retain a compact card unless their source needs more room.
    private static func preferredWidth(for entry: ClipboardEntry, availableWidth: CGFloat) -> CGFloat {
        let text = entry.text ?? entry.previewText
        let font: NSFont = entry.contentCategory == .code
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        let longest = text
            .components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let preferred = longest + horizontalPadding * 2 + 2
        let desired = min(maximumWidth, max(minimumWidth, preferred))
        // When a panel is invoked close to a screen edge, preserve the card
        // inside the visible frame instead of allowing it to overflow.
        return min(desired, max(260, availableWidth))
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
    @State private var pendingPreview: DispatchWorkItem?

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
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private var mainCardXOffset: CGFloat {
        detailPresentation.isVisible && detailPresentation.placement == .left
            ? detailPresentation.cardSize.width + 10
            : 0
    }

    private var detailCardXOffset: CGFloat {
        detailPresentation.placement == .left ? 0 : ClipboardPanelLayout.panelWidth + 10
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
        .background(KeyCaptureView { event in handleKey(event) }.frame(width: 0, height: 0))
        .onAppear {
            validateSelection()
            reportContentHeight()
        }
        .onChange(of: query) { _, _ in selectionAndSizeChanged() }
        .onChange(of: store.settings.lastCategory) { _, _ in selectionAndSizeChanged() }
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
                    cardSize: detailPresentation.cardSize
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
        reportContentHeight()
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
                    .onHover { updateHover($0, entry: entry) }
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
                    .onTapGesture { copy(entry) }
                    .onHover { updateHover($0, entry: entry) }
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
            hoveredID = nil
            cancelPendingPreview()
            onDetailEntry(nil)
        }
    }

    private func schedulePreview(for entry: ClipboardEntry) {
        cancelPendingPreview()
        let entryID = entry.id
        let work = DispatchWorkItem { [weak store] in
            // The ID check prevents a delayed callback from a previous row
            // opening after the pointer has already moved elsewhere.
            guard store != nil, hoveredID == entryID else { return }
            onDetailEntry(entry)
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func cancelPendingPreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
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
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .help("剪贴板内置顶")
            }
            Spacer(minLength: 0)
            if isSelected || isHovered || entry.isDesktopPinned == true {
                ClipboardPinButton(entry: entry, isSelected: isSelected, action: onTogglePin)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardPanelLayout.textRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
        .onHover { isHovered = $0 }
    }
}

private struct CodeEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let onTogglePin: () -> Void

    @State private var isHovered = false

    private var lineCount: Int { ClipboardPanelLayout.previewLineCount(entry.text) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(CodeHighlighter.highlight(previewCode))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(ClipboardPanelLayout.codePreviewMaxLines)
                .lineSpacing(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .help("剪贴板内置顶")
            }
            Spacer(minLength: 0)
            if isSelected || isHovered || entry.isDesktopPinned == true {
                ClipboardPinButton(entry: entry, isSelected: isSelected, action: onTogglePin)
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
            Image(systemName: entry.isDesktopPinned == true ? "pin.fill" : "pin")
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

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}
