import AppKit
import SwiftUI

@MainActor
final class ScreenshotEditorPanelController {
    private var panel: NSPanel?
    private var onComplete: ((NSImage?) -> Void)?

    func edit(image: NSImage, completion: @escaping (NSImage?) -> Void) {
        onComplete = completion
        let panel = makePanel(for: image)
        let content = ScreenshotEditorPanelView(
            image: image,
            onCancel: { [weak self] in self?.finish(image: nil) },
            onSave: { [weak self] editedImage in self?.finish(image: editedImage) },
            onRenderAndSave: { [weak self] request in self?.renderAndFinish(request) }
        )
        SystemSurface.install(content, in: panel, material: .popover, cornerRadius: 18)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        // A capture editor is an active, transient operation.  Ordering it
        // regardless of the current app prevents the captured app from
        // immediately covering the editor again after ScreenCaptureKit exits.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func makePanel(for image: NSImage) -> NSPanel {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 780)
        let panelSize = ScreenshotEditorLayout.panelSize(
            imageSize: image.pixelSize,
            visibleFrame: visibleFrame
        )
        let panelFrame = NSRect(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        let panel = ScreenshotEditorPanel(
            contentRect: panelFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The canvas owns mouse drags for pen, crop, arrows, and rectangles.
        // Letting a borderless panel move from its background steals those
        // drags before the canvas can complete an annotation.
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.setFrame(panelFrame, display: false)
        return panel
    }

    private func finish(image: NSImage?) {
        let completion = dismissAndTakeCompletion()
        completion?(image)
    }

    /// Dismiss before producing a potentially large, annotated bitmap.  The
    /// old sequence left the editor key while rendering, which made the cursor
    /// appear busy after pressing 完成 even though the user had finished.
    private func renderAndFinish(_ request: ScreenshotRenderRequest) {
        guard let completion = dismissAndTakeCompletion() else { return }
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                ScreenshotRenderedImage(ScreenshotRenderer.render(image: request.image, state: request.state))
            }.value
            completion(rendered.image)
        }
    }

    private func dismissAndTakeCompletion() -> ((NSImage?) -> Void)? {
        panel?.orderOut(nil)
        panel = nil
        let completion = onComplete
        onComplete = nil
        return completion
    }
}

private final class ScreenshotEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScreenshotEditorPanelView: View {
    let image: NSImage
    let onCancel: () -> Void
    let onSave: (NSImage) -> Void
    let onRenderAndSave: (ScreenshotRenderRequest) -> Void

    @State private var mode: ScreenshotEditorMode = .pen
    @State private var color: MarkupColor = .red
    @State private var lineWidth = 4.0
    @State private var zoomScale = 1.0
    @State private var canvas = ScreenshotCanvasState()
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScreenshotCanvasViewport(
                image: image,
                mode: $mode,
                color: $color,
                lineWidth: $lineWidth,
                zoomScale: $zoomScale,
                state: $canvas
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar
            compactToolbar
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        // This sits behind the actual controls, so the blank parts of the
        // header can move a borderless editor without stealing button clicks,
        // sliders, or drawing gestures.
        .background(WindowDragGestureRegion())
    }

    /// Wide editors use one native-toolbar-like row.  The fixed minimum width
    /// makes `ViewThatFits` choose the compact version before any trailing
    /// action can be clipped by a small/portrait capture window.
    private var fullToolbar: some View {
        HStack(spacing: 14) {
            closeButton
                .frame(width: 150, alignment: .leading)

            Spacer(minLength: 12)

            markupTools
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)

            actionButtons
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: 1_030)
    }

    /// Portrait and narrow captures keep the cancel/complete actions in the
    /// first row, then give the editing controls their own uncompressed row.
    /// This is deliberately not a clipped/scaled version of the wide toolbar.
    private var compactToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                closeButton
                Spacer(minLength: 8)
                actionButtons
            }
            ScrollView(.horizontal, showsIndicators: false) {
                markupTools
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var closeButton: some View {
        Button(action: onCancel) {
            Label("截屏", systemImage: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("取消截屏")
        .contentShape(Rectangle())
    }

    private var markupTools: some View {
        HStack(spacing: 12) {
            Picker("工具", selection: $mode) {
                ForEach(ScreenshotEditorMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.systemImage)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 248)

            Divider().frame(height: 20)

            HStack(spacing: 5) {
                ForEach(MarkupColor.allCases, id: \.self) { swatch in
                    ColorSwatch(color: swatch, isSelected: color == swatch) { color = swatch }
                }
            }
            .opacity(mode.usesStyle ? 1 : 0.35)
            .disabled(!mode.usesStyle)

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .foregroundStyle(.secondary)
                Slider(value: $lineWidth, in: 1...24)
                    .frame(width: 108)
                    .accessibilityLabel("粗细")
                Text(lineWidth, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .opacity(mode.usesStyle ? 1 : 0.35)
            .disabled(!mode.usesStyle)

            Divider().frame(height: 20)

            HStack(spacing: 3) {
                Button {
                    zoomScale = max(0.25, zoomScale - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("缩小")
                Button {
                    zoomScale = 1
                } label: {
                    Text(zoomScale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(minWidth: 38)
                }
                .help("还原为适合窗口")
                Button {
                    zoomScale = min(4, zoomScale + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("放大")
            }
            .buttonStyle(.borderless)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                canvas.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("撤销")
            .disabled(!canvas.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button {
                canvas.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("重做")
            .disabled(!canvas.canRedo)
            .keyboardShortcut("y", modifiers: .command)

            Button(role: .destructive, action: onCancel) {
                Image(systemName: "trash")
            }
            .help("删除截图")

            Button(action: share) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("共享")

            Button("完成") {
                finishEditing()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isFinishing)
        }
    }

    private func share() {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [ScreenshotRenderer.render(image: image, state: canvas)])
        let anchor = NSRect(x: view.bounds.maxX - 90, y: view.bounds.maxY - 58, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    private func finishEditing() {
        guard !isFinishing else { return }
        isFinishing = true
        // The overwhelmingly common path has no annotations. Returning the
        // original avoids a full-size redraw before the panel closes; PNG
        // encoding is also performed asynchronously by AppServices.
        guard canvas.hasEdits else {
            onSave(image)
            return
        }
        onRenderAndSave(ScreenshotRenderRequest(image: image, state: canvas))
    }
}

private enum ScreenshotEditorLayout {
    // The compact toolbar can occupy two rows.  Reserving that maximum in the
    // initial panel calculation means opening markup controls never covers the
    // capture or pushes a control outside the window.
    static let toolbarHeight: CGFloat = 108
    static let canvasPadding: CGFloat = 32
    static let screenMargin: CGFloat = 16

    static func panelSize(imageSize: NSSize, visibleFrame: NSRect) -> NSSize {
        let maximum = NSSize(
            width: min(1600, max(640, visibleFrame.width - screenMargin * 2)),
            height: min(1200, max(480, visibleFrame.height - screenMargin * 2))
        )
        guard imageSize.width > 0, imageSize.height > 0 else { return maximum }
        let maximumCanvas = NSSize(
            width: max(1, maximum.width - canvasPadding * 2),
            height: max(1, maximum.height - toolbarHeight - canvasPadding * 2)
        )
        let scale = min(maximumCanvas.width / imageSize.width, maximumCanvas.height / imageSize.height)
        let fitted = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSSize(
            width: min(maximum.width, max(680, fitted.width + canvasPadding * 2)),
            height: min(maximum.height, max(460, fitted.height + toolbarHeight + canvasPadding * 2))
        )
    }

    static func fittedImageSize(_ imageSize: NSSize, in viewport: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return viewport }
        let width = max(1, viewport.width - canvasPadding * 2)
        let height = max(1, viewport.height - canvasPadding * 2)
        let scale = min(width / imageSize.width, height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

/// The system editor initially shows the complete capture. The window itself
/// follows the capture aspect ratio, while this final fit protects against
/// unusually small or rotated displays without forcing an initial scroll.
private struct ScreenshotCanvasViewport: View {
    let image: NSImage
    @Binding var mode: ScreenshotEditorMode
    @Binding var color: MarkupColor
    @Binding var lineWidth: Double
    @Binding var zoomScale: Double
    @Binding var state: ScreenshotCanvasState

    var body: some View {
        GeometryReader { geometry in
            let fitted = ScreenshotEditorLayout.fittedImageSize(image.pixelSize, in: geometry.size)
            ScrollView([.horizontal, .vertical]) {
                editor
                    .frame(width: fitted.width * zoomScale, height: fitted.height * zoomScale)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .frame(
                        minWidth: max(0, geometry.size.width - ScreenshotEditorLayout.canvasPadding * 2),
                        minHeight: max(0, geometry.size.height - ScreenshotEditorLayout.canvasPadding * 2),
                        alignment: .center
                    )
                    .padding(ScreenshotEditorLayout.canvasPadding)
            }
            .scrollIndicators(zoomScale > 1 ? .automatic : .hidden)
        }
        .background(Color.primary.opacity(0.025))
    }

    private var editor: some View {
        ScreenshotEditorCanvas(
            image: image,
            mode: $mode,
            color: $color,
            lineWidth: $lineWidth,
            zoomScale: $zoomScale,
            state: $state
        )
    }
}

// MARK: - Tool / style model

private enum ScreenshotEditorMode: CaseIterable {
    case crop
    case pen
    case highlight
    case arrow
    case rectangle
    case text

    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .crop: "裁剪"
        case .pen: "画笔"
        case .highlight: "高亮"
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .text: "文字"
        }
    }

    /// Whether color/width selection applies to this tool.
    var usesStyle: Bool { self != .crop }
}

enum MarkupColor: CaseIterable {
    case red, orange, yellow, green, blue, black, white

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .black: .black
        case .white: .white
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

private struct ColorSwatch: View {
    let color: MarkupColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(.white.opacity(color == .white ? 0.6 : 0.25), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-2)
                )
        }
        .buttonStyle(.plain)
        .help(" ")
    }
}

/// A deliberately empty drag region.  It is the toolbar background rather
/// than an overlay, which keeps all real toolbar controls above it in the hit
/// test order.
private struct WindowDragGestureRegion: View {
    var body: some View {
        HeaderDragRegion()
    }
}

private struct HeaderDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderDragNSView { HeaderDragNSView() }
    func updateNSView(_ view: HeaderDragNSView, context: Context) {}
}

private final class HeaderDragNSView: NSView {
    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Canvas state

private struct RGBAColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(_ nsColor: NSColor) {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? .black
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private struct ScreenshotCanvasState: Equatable {
    var cropRect: CGRect?
    var strokes: [ScreenshotStroke] = []
    var arrows: [ScreenshotArrow] = []
    var rectangles: [ScreenshotRect] = []
    var labels: [ScreenshotLabel] = []
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot: Equatable {
        var cropRect: CGRect?
        var strokes: [ScreenshotStroke]
        var arrows: [ScreenshotArrow]
        var rectangles: [ScreenshotRect]
        var labels: [ScreenshotLabel]

        init(_ state: ScreenshotCanvasState) {
            cropRect = state.cropRect
            strokes = state.strokes
            arrows = state.arrows
            rectangles = state.rectangles
            labels = state.labels
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var hasEdits: Bool {
        cropRect != nil || !strokes.isEmpty || !arrows.isEmpty || !rectangles.isEmpty || !labels.isEmpty
    }

    mutating func saveUndoPoint() {
        undoStack.append(Snapshot(self))
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(self))
        restore(previous)
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(self))
        restore(next)
    }

    private mutating func restore(_ snapshot: Snapshot) {
        cropRect = snapshot.cropRect
        strokes = snapshot.strokes
        arrows = snapshot.arrows
        rectangles = snapshot.rectangles
        labels = snapshot.labels
    }
}

/// NSImage is immutable for the lifetime of an editor operation. These wrappers
/// make that ownership explicit when the expensive annotation render is moved
/// off the main actor.
private struct ScreenshotRenderRequest: @unchecked Sendable {
    let image: NSImage
    let state: ScreenshotCanvasState
}

private struct ScreenshotRenderedImage: @unchecked Sendable {
    let image: NSImage

    init(_ image: NSImage) { self.image = image }
}

private enum ScreenshotStrokeKind: Equatable {
    case pen
    case highlight
}

private struct ScreenshotStroke: Equatable {
    var kind: ScreenshotStrokeKind
    var points: [CGPoint]
    var color: RGBAColor
    var width: CGFloat
}

private struct ScreenshotArrow: Equatable {
    var start: CGPoint
    var end: CGPoint
    var color: RGBAColor
    var width: CGFloat
}

private struct ScreenshotRect: Equatable {
    var rect: CGRect
    var color: RGBAColor
    var width: CGFloat
}

private struct ScreenshotLabel: Equatable {
    var id: UUID = UUID()
    var text: String
    var origin: CGPoint
    var color: RGBAColor
    var fontSize: CGFloat
}

// MARK: - Canvas view

private struct ScreenshotEditorCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var mode: ScreenshotEditorMode
    @Binding var color: MarkupColor
    @Binding var lineWidth: Double
    @Binding var zoomScale: Double
    @Binding var state: ScreenshotCanvasState

    func makeNSView(context: Context) -> ScreenshotCanvasView {
        let view = ScreenshotCanvasView()
        view.image = image
        view.mode = mode
        view.strokeColor = color.nsColor
        view.lineWidth = CGFloat(lineWidth)
        view.zoomScale = CGFloat(zoomScale)
        view.state = state
        view.onStateChange = { state = $0 }
        view.onZoomChange = { zoomScale = Double($0) }
        return view
    }

    func updateNSView(_ view: ScreenshotCanvasView, context: Context) {
        view.image = image
        view.mode = mode
        view.strokeColor = color.nsColor
        view.lineWidth = CGFloat(lineWidth)
        view.zoomScale = CGFloat(zoomScale)
        view.state = state
        view.onZoomChange = { zoomScale = Double($0) }
        view.needsDisplay = true
    }
}

private final class ScreenshotCanvasView: NSView {
    var image: NSImage = NSImage()
    var mode: ScreenshotEditorMode = .pen
    var strokeColor: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var zoomScale: CGFloat = 1
    var state = ScreenshotCanvasState()
    var onStateChange: ((ScreenshotCanvasState) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?

    private var activePoints = [CGPoint]()
    private var activeStart: CGPoint?
    private var activeCurrent: CGPoint?
    private var movingLabelID: UUID?
    private var movingLabelOffset: CGPoint = .zero
    private var selectedLabelID: UUID?
    private var lastImagePoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let imageRect = fittedImageRect
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        drawAnnotations(in: imageRect)
        drawActive(in: imageRect)
        drawCropOverlay(in: imageRect)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = imagePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        lastImagePoint = point
        if let label = label(at: point) {
            state.saveUndoPoint()
            selectedLabelID = label.id
            movingLabelID = label.id
            movingLabelOffset = CGPoint(x: point.x - label.origin.x, y: point.y - label.origin.y)
            needsDisplay = true
            return
        }
        activeStart = point
        activeCurrent = point
        activePoints = [point]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        lastImagePoint = point
        if let id = movingLabelID, let index = state.labels.firstIndex(where: { $0.id == id }) {
            state.labels[index].origin = clampedLabelOrigin(
                CGPoint(x: point.x - movingLabelOffset.x, y: point.y - movingLabelOffset.y),
                for: state.labels[index]
            )
            onStateChange?(state)
            needsDisplay = true
            return
        }
        activeCurrent = point
        if mode == .pen || mode == .highlight { activePoints.append(point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if movingLabelID != nil {
            movingLabelID = nil
            onStateChange?(state)
            needsDisplay = true
            return
        }
        guard let start = activeStart,
              let end = imagePoint(for: convert(event.locationInWindow, from: nil)) ?? activeCurrent else {
            resetActive()
            return
        }
        let color = RGBAColor(strokeColor)
        switch mode {
        case .crop:
            let rect = normalizedRect(from: start, to: end)
            if rect.width >= 4, rect.height >= 4 {
                state.saveUndoPoint()
                state.cropRect = rect
            }
        case .pen:
            if activePoints.count > 1 {
                state.saveUndoPoint()
                state.strokes.append(ScreenshotStroke(kind: .pen, points: activePoints, color: color, width: lineWidth))
            }
        case .highlight:
            if activePoints.count > 1 {
                state.saveUndoPoint()
                state.strokes.append(ScreenshotStroke(kind: .highlight, points: activePoints, color: color, width: lineWidth * 3))
            }
        case .arrow:
            if distance(from: start, to: end) >= 4 {
                state.saveUndoPoint()
                state.arrows.append(ScreenshotArrow(start: start, end: end, color: color, width: lineWidth))
            }
        case .rectangle:
            let rect = normalizedRect(from: start, to: end)
            if rect.width >= 4, rect.height >= 4 {
                state.saveUndoPoint()
                state.rectangles.append(ScreenshotRect(rect: rect, color: color, width: lineWidth))
            }
        case .text:
            promptForText(at: end, color: color)
        }
        resetActive()
        onStateChange?(state)
        needsDisplay = true
    }

    private func drawAnnotations(in imageRect: CGRect) {
        for stroke in state.strokes { draw(stroke: stroke, in: imageRect) }
        for rect in state.rectangles { draw(rect: rect, in: imageRect) }
        for arrow in state.arrows { draw(arrow: arrow, in: imageRect) }
        for label in state.labels { draw(label: label, in: imageRect) }
        if let selectedLabelID,
           let label = state.labels.first(where: { $0.id == selectedLabelID }) {
            let bounds = labelRect(for: label, in: imageRect).insetBy(dx: -4, dy: -3)
            NSColor.controlAccentColor.setStroke()
            let selection = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
            selection.lineWidth = 1.5
            selection.setLineDash([4, 3], count: 2, phase: 0)
            selection.stroke()
        }
    }

    private func drawActive(in imageRect: CGRect) {
        let color = RGBAColor(strokeColor)
        switch mode {
        case .pen where activePoints.count > 1:
            draw(stroke: ScreenshotStroke(kind: .pen, points: activePoints, color: color, width: lineWidth), in: imageRect)
        case .highlight where activePoints.count > 1:
            draw(stroke: ScreenshotStroke(kind: .highlight, points: activePoints, color: color, width: lineWidth * 3), in: imageRect)
        case .arrow:
            if let start = activeStart, let end = activeCurrent {
                draw(arrow: ScreenshotArrow(start: start, end: end, color: color, width: lineWidth), in: imageRect)
            }
        case .rectangle:
            if let start = activeStart, let end = activeCurrent {
                draw(rect: ScreenshotRect(rect: normalizedRect(from: start, to: end), color: color, width: lineWidth), in: imageRect)
            }
        default:
            break
        }
    }

    private func drawCropOverlay(in imageRect: CGRect) {
        let crop = activeCropRect ?? state.cropRect
        guard let crop else { return }
        let viewRect = viewRect(for: crop, in: imageRect)
        let overlay = NSBezierPath(rect: imageRect)
        overlay.append(NSBezierPath(rect: viewRect))
        overlay.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill()
        overlay.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: viewRect, xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.stroke()
    }

    private func draw(stroke: ScreenshotStroke, in imageRect: CGRect) {
        guard stroke.points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: viewPoint(for: stroke.points[0], in: imageRect))
        for point in stroke.points.dropFirst() {
            path.line(to: viewPoint(for: point, in: imageRect))
        }
        switch stroke.kind {
        case .pen:
            stroke.color.nsColor.setStroke()
            path.lineWidth = stroke.width * imageScale(in: imageRect)
        case .highlight:
            stroke.color.nsColor.withAlphaComponent(0.4).setStroke()
            path.lineWidth = stroke.width * imageScale(in: imageRect)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func draw(rect: ScreenshotRect, in imageRect: CGRect) {
        let viewRect = viewRect(for: rect.rect, in: imageRect)
        let path = NSBezierPath(roundedRect: viewRect, xRadius: 3, yRadius: 3)
        rect.color.nsColor.setStroke()
        path.lineWidth = rect.width * imageScale(in: imageRect)
        path.stroke()
    }

    private func draw(arrow: ScreenshotArrow, in imageRect: CGRect) {
        let start = viewPoint(for: arrow.start, in: imageRect)
        let end = viewPoint(for: arrow.end, in: imageRect)
        let width = arrow.width * imageScale(in: imageRect)
        arrow.color.nsColor.setStroke()
        let line = NSBezierPath()
        line.lineWidth = width
        line.lineCapStyle = .round
        line.move(to: start)
        line.line(to: end)
        line.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(width * 3.5, 12)
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let point = NSPoint(
                x: end.x + cos(angle + offset) * headLength,
                y: end.y + sin(angle + offset) * headLength
            )
            let head = NSBezierPath()
            head.lineWidth = width
            head.lineCapStyle = .round
            head.move(to: end)
            head.line(to: point)
            head.stroke()
        }
    }

    private func draw(label: ScreenshotLabel, in imageRect: CGRect) {
        let point = viewPoint(for: label.origin, in: imageRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.fontSize * imageScale(in: imageRect), weight: .semibold),
            .foregroundColor: label.color.nsColor,
        ]
        label.text.draw(at: point, withAttributes: attributes)
    }

    private func label(at imagePoint: CGPoint) -> ScreenshotLabel? {
        state.labels.reversed().first { label in
            labelRectInImage(for: label).insetBy(dx: -8, dy: -8).contains(imagePoint)
        }
    }

    private func labelRect(for label: ScreenshotLabel, in imageRect: CGRect) -> CGRect {
        let origin = viewPoint(for: label.origin, in: imageRect)
        let font = NSFont.systemFont(ofSize: label.fontSize * imageScale(in: imageRect), weight: .semibold)
        let size = (label.text as NSString).size(withAttributes: [.font: font])
        return CGRect(origin: origin, size: size)
    }

    private func labelRectInImage(for label: ScreenshotLabel) -> CGRect {
        let font = NSFont.systemFont(ofSize: label.fontSize, weight: .semibold)
        let size = (label.text as NSString).size(withAttributes: [.font: font])
        return CGRect(origin: label.origin, size: size)
    }

    private func clampedLabelOrigin(_ origin: CGPoint, for label: ScreenshotLabel) -> CGPoint {
        clampedLabelOrigin(origin, text: label.text, fontSize: label.fontSize)
    }

    private func clampedLabelOrigin(_ origin: CGPoint, text: String, fontSize: CGFloat) -> CGPoint {
        let imageSize = image.pixelSize
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGPoint(
            x: min(max(origin.x, 0), max(0, imageSize.width - size.width)),
            y: min(max(origin.y, 0), max(0, imageSize.height - size.height))
        )
    }

    private func promptForText(at point: CGPoint, color: RGBAColor) {
        let alert = NSAlert()
        alert.messageText = "添加文字"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "输入标注文字"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addLabel(text, at: point, color: color)
        onStateChange?(state)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case "z":
            if modifiers.contains(.shift) { state.redo() } else { state.undo() }
            onStateChange?(state)
            needsDisplay = true
        case "y":
            state.redo()
            onStateChange?(state)
            needsDisplay = true
        case "v":
            pasteTextAnnotation()
        default:
            super.keyDown(with: event)
        }
    }

    private func pasteTextAnnotation() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let point = lastImagePoint ?? CGPoint(x: image.pixelSize.width / 2, y: image.pixelSize.height / 2)
        addLabel(text, at: point, color: RGBAColor(strokeColor))
        onStateChange?(state)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // A plain wheel/trackpad scroll adjusts the canvas scale as requested;
        // once enlarged, the surrounding SwiftUI scroll view provides panning.
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        updateZoom(by: exp(-delta * 0.012))
    }

    override func magnify(with event: NSEvent) {
        updateZoom(by: 1 + event.magnification)
    }

    private func updateZoom(by factor: CGFloat) {
        let next = min(4, max(0.25, zoomScale * factor))
        guard abs(next - zoomScale) > 0.001 else { return }
        zoomScale = next
        onZoomChange?(next)
    }

    private func addLabel(_ text: String, at point: CGPoint, color: RGBAColor) {
        state.saveUndoPoint()
        let label = ScreenshotLabel(
            text: text,
            origin: clampedLabelOrigin(point, text: text, fontSize: 22),
            color: color,
            fontSize: 22
        )
        state.labels.append(label)
        selectedLabelID = label.id
    }

    private var fittedImageRect: CGRect {
        let size = image.pixelSize
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    private func imageScale(in imageRect: CGRect) -> CGFloat {
        let size = image.pixelSize
        guard size.width > 0 else { return 1 }
        return imageRect.width / size.width
    }

    private var activeCropRect: CGRect? {
        guard mode == .crop, let activeStart, let activeCurrent else { return nil }
        return normalizedRect(from: activeStart, to: activeCurrent)
    }

    private func imagePoint(for viewPoint: CGPoint) -> CGPoint? {
        let rect = fittedImageRect
        guard rect.contains(viewPoint) else { return nil }
        let size = image.pixelSize
        let scaleX = size.width / rect.width
        let scaleY = size.height / rect.height
        return CGPoint(x: (viewPoint.x - rect.minX) * scaleX, y: (viewPoint.y - rect.minY) * scaleY)
    }

    private func viewPoint(for imagePoint: CGPoint, in imageRect: CGRect) -> CGPoint {
        let size = image.pixelSize
        return CGPoint(
            x: imageRect.minX + imagePoint.x / max(size.width, 1) * imageRect.width,
            y: imageRect.minY + imagePoint.y / max(size.height, 1) * imageRect.height
        )
    }

    private func viewRect(for imageRectValue: CGRect, in imageRect: CGRect) -> CGRect {
        let origin = viewPoint(for: imageRectValue.origin, in: imageRect)
        let maxPoint = viewPoint(for: CGPoint(x: imageRectValue.maxX, y: imageRectValue.maxY), in: imageRect)
        return normalizedRect(from: origin, to: maxPoint)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func resetActive() {
        activeStart = nil
        activeCurrent = nil
        activePoints = []
    }
}

// MARK: - Renderer

private enum ScreenshotRenderer {
    static func render(image: NSImage, state: ScreenshotCanvasState) -> NSImage {
        let fullSize = image.pixelSize
        let crop = state.cropRect?.intersection(CGRect(origin: .zero, size: fullSize)) ?? CGRect(origin: .zero, size: fullSize)
        let outputSize = NSSize(width: max(crop.width, 1), height: max(crop.height, 1))
        let rendered = NSImage(size: outputSize)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: crop,
            operation: .sourceOver,
            fraction: 1
        )
        let offsetState = offset(state: state, by: crop.origin)
        for stroke in offsetState.strokes { draw(stroke: stroke) }
        for rect in offsetState.rectangles { draw(rect: rect) }
        for arrow in offsetState.arrows { draw(arrow: arrow) }
        for label in offsetState.labels { draw(label: label) }
        rendered.unlockFocus()
        return rendered
    }

    private static func offset(state: ScreenshotCanvasState, by origin: CGPoint) -> ScreenshotCanvasState {
        var updated = state
        updated.cropRect = nil
        updated.strokes = updated.strokes.map { stroke in
            ScreenshotStroke(
                kind: stroke.kind,
                points: stroke.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) },
                color: stroke.color,
                width: stroke.width
            )
        }
        updated.rectangles = updated.rectangles.map {
            ScreenshotRect(rect: $0.rect.offsetBy(dx: -origin.x, dy: -origin.y), color: $0.color, width: $0.width)
        }
        updated.arrows = updated.arrows.map {
            ScreenshotArrow(
                start: CGPoint(x: $0.start.x - origin.x, y: $0.start.y - origin.y),
                end: CGPoint(x: $0.end.x - origin.x, y: $0.end.y - origin.y),
                color: $0.color,
                width: $0.width
            )
        }
        updated.labels = updated.labels.map {
            ScreenshotLabel(text: $0.text, origin: CGPoint(x: $0.origin.x - origin.x, y: $0.origin.y - origin.y), color: $0.color, fontSize: $0.fontSize)
        }
        return updated
    }

    private static func draw(stroke: ScreenshotStroke) {
        guard stroke.points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: stroke.points[0])
        for point in stroke.points.dropFirst() { path.line(to: point) }
        switch stroke.kind {
        case .pen: stroke.color.nsColor.setStroke()
        case .highlight: stroke.color.nsColor.withAlphaComponent(0.4).setStroke()
        }
        path.lineWidth = stroke.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func draw(rect: ScreenshotRect) {
        let path = NSBezierPath(roundedRect: rect.rect, xRadius: 3, yRadius: 3)
        rect.color.nsColor.setStroke()
        path.lineWidth = rect.width
        path.stroke()
    }

    private static func draw(arrow: ScreenshotArrow) {
        arrow.color.nsColor.setStroke()
        let line = NSBezierPath()
        line.lineWidth = arrow.width
        line.lineCapStyle = .round
        line.move(to: arrow.start)
        line.line(to: arrow.end)
        line.stroke()

        let angle = atan2(arrow.end.y - arrow.start.y, arrow.end.x - arrow.start.x)
        let headLength = max(arrow.width * 3.5, 14)
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let point = NSPoint(
                x: arrow.end.x + cos(angle + offset) * headLength,
                y: arrow.end.y + sin(angle + offset) * headLength
            )
            let head = NSBezierPath()
            head.lineWidth = arrow.width
            head.lineCapStyle = .round
            head.move(to: arrow.end)
            head.line(to: point)
            head.stroke()
        }
    }

    private static func draw(label: ScreenshotLabel) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.fontSize, weight: .semibold),
            .foregroundColor: label.color.nsColor,
        ]
        label.text.draw(at: label.origin, withAttributes: attributes)
    }
}

private extension NSImage {
    var pixelSize: NSSize {
        if let representation = representations.first {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }
}
