import AppKit
import SwiftUI

@MainActor
final class ScreenshotEditorPanelController {
    private var panel: NSPanel?
    private var onComplete: ((NSImage?) -> Void)?

    func edit(image: NSImage, completion: @escaping (NSImage?) -> Void) {
        onComplete = completion
        let panel = makePanel(for: image)
        panel.contentView = NSHostingView(rootView: ScreenshotEditorPanelView(
            image: image,
            onCancel: { [weak self] in self?.finish(image: nil) },
            onSave: { [weak self] editedImage in self?.finish(image: editedImage) }
        ))
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel(for image: NSImage) -> NSPanel {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 780)
        let size = image.pixelSize
        let maxWidth = min(screenFrame.width - 80, 980)
        let maxHeight = min(screenFrame.height - 80, 760)
        let scale = min(maxWidth / max(size.width, 1), (maxHeight - 70) / max(size.height, 1), 1)
        let panelSize = NSSize(width: max(size.width * scale, 520), height: max(size.height * scale + 70, 420))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图编辑"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .managed]
        return panel
    }

    private func finish(image: NSImage?) {
        panel?.orderOut(nil)
        panel = nil
        let completion = onComplete
        onComplete = nil
        completion?(image)
    }
}

private struct ScreenshotEditorPanelView: View {
    let image: NSImage
    let onCancel: () -> Void
    let onSave: (NSImage) -> Void

    @State private var mode: ScreenshotEditorMode = .crop
    @State private var canvas = ScreenshotCanvasState()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScreenshotEditorCanvas(
                image: image,
                mode: $mode,
                state: $canvas
            )
            .background(Color.black.opacity(0.08))
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(VisualEffectBackground())
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("工具", selection: $mode) {
                ForEach(ScreenshotEditorMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)
            Button(action: { canvas.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("撤销")
            .disabled(!canvas.canUndo)
            Spacer()
            Button("取消", action: onCancel)
            Button("完成") {
                onSave(ScreenshotRenderer.render(image: image, state: canvas))
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private enum ScreenshotEditorMode: CaseIterable {
    case crop
    case pen
    case highlight
    case arrow
    case text

    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .pen: "pencil"
        case .highlight: "highlighter"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }
}

private struct ScreenshotCanvasState: Equatable {
    var cropRect: CGRect?
    var strokes: [ScreenshotStroke] = []
    var arrows: [ScreenshotArrow] = []
    var labels: [ScreenshotLabel] = []

    var canUndo: Bool {
        cropRect != nil || !strokes.isEmpty || !arrows.isEmpty || !labels.isEmpty
    }

    mutating func undo() {
        if !labels.isEmpty {
            labels.removeLast()
        } else if !arrows.isEmpty {
            arrows.removeLast()
        } else if !strokes.isEmpty {
            strokes.removeLast()
        } else {
            cropRect = nil
        }
    }
}

private enum ScreenshotStrokeKind: Equatable {
    case pen
    case highlight
}

private struct ScreenshotStroke: Equatable {
    var kind: ScreenshotStrokeKind
    var points: [CGPoint]
}

private struct ScreenshotArrow: Equatable {
    var start: CGPoint
    var end: CGPoint
}

private struct ScreenshotLabel: Equatable {
    var text: String
    var origin: CGPoint
}

private struct ScreenshotEditorCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var mode: ScreenshotEditorMode
    @Binding var state: ScreenshotCanvasState

    func makeNSView(context: Context) -> ScreenshotCanvasView {
        let view = ScreenshotCanvasView()
        view.image = image
        view.mode = mode
        view.state = state
        view.onStateChange = { state = $0 }
        return view
    }

    func updateNSView(_ view: ScreenshotCanvasView, context: Context) {
        view.image = image
        view.mode = mode
        view.state = state
        view.needsDisplay = true
    }
}

private final class ScreenshotCanvasView: NSView {
    var image: NSImage = NSImage()
    var mode: ScreenshotEditorMode = .crop
    var state = ScreenshotCanvasState()
    var onStateChange: ((ScreenshotCanvasState) -> Void)?

    private var activePoints = [CGPoint]()
    private var activeStart: CGPoint?
    private var activeCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let imageRect = fittedImageRect
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        drawAnnotations(in: imageRect)
        drawActive(in: imageRect)
        drawCropOverlay(in: imageRect)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = imagePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        activeStart = point
        activeCurrent = point
        activePoints = [point]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        activeCurrent = point
        if mode == .pen || mode == .highlight { activePoints.append(point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = activeStart,
              let end = imagePoint(for: convert(event.locationInWindow, from: nil)) ?? activeCurrent else {
            resetActive()
            return
        }
        switch mode {
        case .crop:
            let rect = normalizedRect(from: start, to: end)
            if rect.width >= 4, rect.height >= 4 { state.cropRect = rect }
        case .pen:
            if activePoints.count > 1 { state.strokes.append(ScreenshotStroke(kind: .pen, points: activePoints)) }
        case .highlight:
            if activePoints.count > 1 { state.strokes.append(ScreenshotStroke(kind: .highlight, points: activePoints)) }
        case .arrow:
            if distance(from: start, to: end) >= 4 { state.arrows.append(ScreenshotArrow(start: start, end: end)) }
        case .text:
            promptForText(at: end)
        }
        resetActive()
        onStateChange?(state)
        needsDisplay = true
    }

    private func drawAnnotations(in imageRect: CGRect) {
        for stroke in state.strokes { draw(stroke: stroke, in: imageRect) }
        for arrow in state.arrows { draw(arrow: arrow, in: imageRect) }
        for label in state.labels { draw(label: label, in: imageRect) }
    }

    private func drawActive(in imageRect: CGRect) {
        switch mode {
        case .pen where activePoints.count > 1:
            draw(stroke: ScreenshotStroke(kind: .pen, points: activePoints), in: imageRect)
        case .highlight where activePoints.count > 1:
            draw(stroke: ScreenshotStroke(kind: .highlight, points: activePoints), in: imageRect)
        case .arrow:
            if let start = activeStart, let end = activeCurrent { draw(arrow: ScreenshotArrow(start: start, end: end), in: imageRect) }
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
            NSColor.systemRed.setStroke()
            path.lineWidth = 3
        case .highlight:
            NSColor.systemYellow.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 12
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func draw(arrow: ScreenshotArrow, in imageRect: CGRect) {
        let start = viewPoint(for: arrow.start, in: imageRect)
        let end = viewPoint(for: arrow.end, in: imageRect)
        NSColor.systemRed.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 3
        line.lineCapStyle = .round
        line.move(to: start)
        line.line(to: end)
        line.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 14
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let point = NSPoint(
                x: end.x + cos(angle + offset) * headLength,
                y: end.y + sin(angle + offset) * headLength
            )
            let head = NSBezierPath()
            head.lineWidth = 3
            head.move(to: end)
            head.line(to: point)
            head.stroke()
        }
    }

    private func draw(label: ScreenshotLabel, in imageRect: CGRect) {
        let point = viewPoint(for: label.origin, in: imageRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        label.text.draw(at: point, withAttributes: attributes)
    }

    private func promptForText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "添加文字"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "输入标注文字"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.labels.append(ScreenshotLabel(text: text, origin: point))
    }

    private var fittedImageRect: CGRect {
        let size = image.pixelSize
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
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
        for arrow in offsetState.arrows { draw(arrow: arrow) }
        for label in offsetState.labels { draw(label: label) }
        rendered.unlockFocus()
        return rendered
    }

    private static func offset(state: ScreenshotCanvasState, by origin: CGPoint) -> ScreenshotCanvasState {
        var updated = state
        updated.cropRect = nil
        updated.strokes = updated.strokes.map { stroke in
            ScreenshotStroke(kind: stroke.kind, points: stroke.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) })
        }
        updated.arrows = updated.arrows.map {
            ScreenshotArrow(
                start: CGPoint(x: $0.start.x - origin.x, y: $0.start.y - origin.y),
                end: CGPoint(x: $0.end.x - origin.x, y: $0.end.y - origin.y)
            )
        }
        updated.labels = updated.labels.map {
            ScreenshotLabel(text: $0.text, origin: CGPoint(x: $0.origin.x - origin.x, y: $0.origin.y - origin.y))
        }
        return updated
    }

    private static func draw(stroke: ScreenshotStroke) {
        guard stroke.points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: stroke.points[0])
        for point in stroke.points.dropFirst() { path.line(to: point) }
        switch stroke.kind {
        case .pen:
            NSColor.systemRed.setStroke()
            path.lineWidth = 4
        case .highlight:
            NSColor.systemYellow.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 14
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func draw(arrow: ScreenshotArrow) {
        NSColor.systemRed.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 4
        line.lineCapStyle = .round
        line.move(to: arrow.start)
        line.line(to: arrow.end)
        line.stroke()

        let angle = atan2(arrow.end.y - arrow.start.y, arrow.end.x - arrow.start.x)
        let headLength: CGFloat = 18
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let point = NSPoint(
                x: arrow.end.x + cos(angle + offset) * headLength,
                y: arrow.end.y + sin(angle + offset) * headLength
            )
            let head = NSBezierPath()
            head.lineWidth = 4
            head.move(to: arrow.end)
            head.line(to: point)
            head.stroke()
        }
    }

    private static func draw(label: ScreenshotLabel) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.55)
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
