import AppKit
import Foundation

@MainActor
public final class ClipboardCaptureService {
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private var observedChangeCount: Int
    private let onImage: (ImageAssetData) -> Void

    public init(pasteboard: NSPasteboard = .general, onImage: @escaping (ImageAssetData) -> Void) {
        self.pasteboard = pasteboard
        observedChangeCount = pasteboard.changeCount
        self.onImage = onImage
    }

    public func start() {
        stop()
        observedChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.inspectPasteboard()
            }
        }
        // Let the OS coalesce this poll's wakeups with other timers to reduce
        // energy use while meme capture is active.
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Immediately inspects the configured pasteboard. The timer calls this in
    /// production; keeping it internal lets the isolated regression test prove
    /// the exact image-capture path without touching the user's clipboard.
    func inspectPasteboard() {
        guard pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        // Only consume image bytes already present on the pasteboard. Resolving
        // Finder file URLs can cross into Documents/Desktop and makes a menu-bar
        // utility request broad folder permission after each rebuilt signature.
        guard let image = ImageAssetData.read(from: pasteboard, allowFileURLs: false) else { return }
        onImage(image)
    }
}
