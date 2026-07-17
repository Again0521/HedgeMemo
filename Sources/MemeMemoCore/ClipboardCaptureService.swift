import AppKit
import Foundation

@MainActor
public final class ClipboardCaptureService {
    private var timer: Timer?
    private var observedChangeCount = NSPasteboard.general.changeCount
    private let onImage: (ImageAssetData) -> Void

    public init(onImage: @escaping (ImageAssetData) -> Void) {
        self.onImage = onImage
    }

    public func start() {
        stop()
        observedChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.inspectPasteboard()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func inspectPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        // Only consume image bytes already present on the pasteboard. Resolving
        // Finder file URLs can cross into Documents/Desktop and makes a menu-bar
        // utility request broad folder permission after each rebuilt signature.
        guard let image = ImageAssetData.read(from: pasteboard, allowFileURLs: false) else { return }
        onImage(image)
    }
}
