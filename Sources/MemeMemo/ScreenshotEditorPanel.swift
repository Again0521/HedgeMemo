import AppKit
import SwiftUI

@MainActor
final class ScreenshotEditorPanelController {
    private var panel: NSPanel?
    private var onComplete: ((NSImage?) -> Void)?

    func edit(image: NSImage, completion: @escaping (NSImage?) -> Void) {
        onComplete = completion
        let panel = makePanel()
        let content = ScreenshotEditorPanelView(
            image: image,
            onCancel: { [weak self] in self?.finish(image: nil) },
            onSave: { [weak self] editedImage in self?.finish(image: editedImage) }
        )
        SystemSurface.install(content, in: panel, material: .popover, cornerRadius: 18)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 780)
        let panelSize = NSSize(
            width: min(1480, max(760, visibleFrame.width * 0.84)),
            height: min(1120, max(600, visibleFrame.height * 0.78))
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
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setFrame(panelFrame, display: false)
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

private final class ScreenshotEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScreenshotEditorPanelView: View {
    let image: NSImage
    let onCancel: () -> Void
    let onSave: (NSImage) -> Void

    @State private var mode: ScreenshotEditorMode = .pen
    @State private var color: MarkupColor = .red
    @State private var width: MarkupWidth = .medium
    @State private var canvas = ScreenshotCanvasState()
    @State private var showsMarkupTools = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScreenshotCanvasViewport(
                image: image,
                mode: $mode,
                color: $color,
                width: $width,
                state: $canvas,
                allowsEditing: showsMarkupTools
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: onCancel) {
                Label("截屏", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 180, alignment: .leading)

            Spacer(minLength: 12)

            if showsMarkupTools {
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

                Picker("粗细", selection: $width) {
                    ForEach(MarkupWidth.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 64)
                .opacity(mode.usesStyle ? 1 : 0.35)
                .disabled(!mode.usesStyle)
            }

            Spacer(minLength: 12)

            HStack(spacing: 14) {
                if showsMarkupTools {
                    Button {
                        canvas.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("撤销")
                    .disabled(!canvas.canUndo)
                }

                Button {
                    showsMarkupTools.toggle()
                } label: {
                    Image(systemName: "pencil.tip.crop.circle")
                }
                .help(showsMarkupTools ? "隐藏标注工具" : "显示标注工具")

                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "trash")
                }
                .help("删除截图")

                Button(action: share) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("共享")

                Button("完成") {
                    onSave(ScreenshotRenderer.render(image: image, state: canvas))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .frame(width: 220, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private func share() {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [ScreenshotRenderer.render(image: image, state: canvas)])
        let anchor = NSRect(x: view.bounds.maxX - 90, y: view.bounds.maxY - 58, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}

/// Matches the system screenshot editor's long-image behavior: ordinary
/// screenshots fit in the canvas, while tall captures fit to the available
/// width and scroll vertically instead of shrinking into an unreadable strip.
private struct ScreenshotCanvasViewport: View {
    let image: NSImage
    @Binding var mode: ScreenshotEditorMode
    @Binding var color: MarkupColor
    @Binding var width: MarkupWidth
    @Binding var state: ScreenshotCanvasState
    let allowsEditing: Bool

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let imageSize = image.pixelSize
            let contentWidth = max(viewport.width - 64, 1)
            let widthFittedHeight = imageSize.width > 0 ? contentWidth * imageSize.height / imageSize.width : viewport.height
            if widthFittedHeight > viewport.height - 64 {
                ScrollView(.vertical) {
                    editor
                        .frame(width: contentWidth, height: widthFittedHeight)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
                .scrollIndicators(.visible)
            } else {
                editor
                    .padding(32)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private var editor: some View {
        ScreenshotEditorCanvas(
            image: image,
            mode: $mode,
            color: $color,
            width: $width,
            state: $state
        )
        .allowsHitTesting(allowsEditing)
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

private enum MarkupWidth: CaseIterable {
    case thin, medium, thick

    var title: String {
        switch self {
        case .thin: "细"
        case .medium: "中"
        case .thick: "粗"
        }
    }

    var value: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 7
        }
    }
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
    var history: [HistoryEntry] = []

    enum HistoryEntry: Equatable {
        case crop
        case stroke
        case arrow
        case rectangle
        case label
    }

    var canUndo: Bool { !history.isEmpty }

    mutating func undo() {
        guard let last = history.popLast() else { return }
        switch last {
        case .crop: cropRect = nil
        case .stroke: if !strokes.isEmpty { strokes.removeLast() }
        case .arrow: if !arrows.isEmpty { arrows.removeLast() }
        case .rectangle: if !rectangles.isEmpty { rectangles.removeLast() }
        case .label: if !labels.isEmpty { labels.removeLast() }
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
    @Binding var width: MarkupWidth
    @Binding var state: ScreenshotCanvasState

    func makeNSView(context: Context) -> ScreenshotCanvasView {
        let view = ScreenshotCanvasView()
        view.image = image
        view.mode = mode
        view.strokeColor = color.nsColor
        view.lineWidth = width.value
        view.state = state
        view.onStateChange = { state = $0 }
        return view
    }

    func updateNSView(_ view: ScreenshotCanvasView, context: Context) {
        view.image = image
        view.mode = mode
        view.strokeColor = color.nsColor
        view.lineWidth = width.value
        view.state = state
        view.needsDisplay = true
    }
}

private final class ScreenshotCanvasView: NSView {
    var image: NSImage = NSImage()
    var mode: ScreenshotEditorMode = .pen
    var strokeColor: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var state = ScreenshotCanvasState()
    var onStateChange: ((ScreenshotCanvasState) -> Void)?

    private var activePoints = [CGPoint]()
    private var activeStart: CGPoint?
    private var activeCurrent: CGPoint?

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
        let color = RGBAColor(strokeColor)
        switch mode {
        case .crop:
            let rect = normalizedRect(from: start, to: end)
            if rect.width >= 4, rect.height >= 4 {
                state.cropRect = rect
                state.history.append(.crop)
            }
        case .pen:
            if activePoints.count > 1 {
                state.strokes.append(ScreenshotStroke(kind: .pen, points: activePoints, color: color, width: lineWidth))
                state.history.append(.stroke)
            }
        case .highlight:
            if activePoints.count > 1 {
                state.strokes.append(ScreenshotStroke(kind: .highlight, points: activePoints, color: color, width: lineWidth * 3))
                state.history.append(.stroke)
            }
        case .arrow:
            if distance(from: start, to: end) >= 4 {
                state.arrows.append(ScreenshotArrow(start: start, end: end, color: color, width: lineWidth))
                state.history.append(.arrow)
            }
        case .rectangle:
            let rect = normalizedRect(from: start, to: end)
            if rect.width >= 4, rect.height >= 4 {
                state.rectangles.append(ScreenshotRect(rect: rect, color: color, width: lineWidth))
                state.history.append(.rectangle)
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
        state.labels.append(ScreenshotLabel(text: text, origin: point, color: color, fontSize: 22))
        state.history.append(.label)
        onStateChange?(state)
        needsDisplay = true
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
