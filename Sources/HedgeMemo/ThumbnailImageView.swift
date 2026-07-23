import AppKit
import ImageIO
import SwiftUI

/// Moves a non-`Sendable` value across a dispatch boundary. The values here are
/// only ever handed off (produced on one queue, consumed on another), never
/// mutated concurrently, so this is safe.
private struct Sendify<T>: @unchecked Sendable { let value: T }

/// Shared, downsampled-thumbnail cache for the scrolling image grids (clipboard
/// 图片/截图 and the meme popup). The grids previously decoded every cell's file
/// at full resolution on the main thread with no cache, so scrolling back and
/// forth re-decoded the same megabytes each time — the source of the stutter.
///
/// Thumbnails are decoded once, off the main thread, at the cell's display size
/// (× the screen scale), so there is no visible quality loss; animated images
/// keep every frame so GIFs still play.
final class ImageThumbnailCache: @unchecked Sendable {
    static let shared = ImageThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let lifecycleLock = NSLock()
    private var idlePurgeWork: DispatchWorkItem?
    private var lifecycleGeneration: UInt = 0
    /// A small shared queue prevents a newly opened page from starting one
    /// full image decode per visible cell at once. Two workers keep scrolling
    /// responsive without competing with SwiftUI/AppKit for every CPU core.
    let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.hedgememo.thumbnail-decoding"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024 // ~64 MB of decoded thumbnails
    }

    func cached(for key: NSString) -> NSImage? { cache.object(forKey: key) }

    func store(_ thumbnail: DecodedThumbnail, for key: NSString) {
        cache.setObject(thumbnail.image, forKey: key, cost: max(1, thumbnail.decodedByteCost))
    }

    /// A recently closed panel is likely to be reopened, so keep warm thumbnails
    /// briefly. If HedgeMemo stays silent, release both decoded images and queued
    /// off-screen work; original files remain untouched on disk.
    func beginInteractiveUse() {
        lifecycleLock.withLock {
            lifecycleGeneration &+= 1
            idlePurgeWork?.cancel()
            idlePurgeWork = nil
        }
    }

    func scheduleIdlePurge(after delay: TimeInterval = 30) {
        let ticket = lifecycleLock.withLock { () -> UInt in
            lifecycleGeneration &+= 1
            idlePurgeWork?.cancel()
            idlePurgeWork = nil
            return lifecycleGeneration
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrentLifecycle(ticket) else { return }
            self.decodeQueue.cancelAllOperations()
            self.cache.removeAllObjects()
            // A decode already running when cancellation arrives can still store
            // its result afterwards. Purge again behind the queue's running work,
            // but only if no panel has reopened in the meantime.
            self.decodeQueue.addBarrierBlock { [weak self] in
                guard let self, self.isCurrentLifecycle(ticket) else { return }
                self.cache.removeAllObjects()
            }
            self.lifecycleLock.withLock {
                if self.lifecycleGeneration == ticket { self.idlePurgeWork = nil }
            }
        }
        lifecycleLock.withLock {
            if lifecycleGeneration == ticket { idlePurgeWork = work }
            else { work.cancel() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func isCurrentLifecycle(_ ticket: UInt) -> Bool {
        lifecycleLock.withLock { lifecycleGeneration == ticket }
    }

    /// Path + requested size + content identity. Clipboard and meme models
    /// already carry a SHA-256 hash, so their scrolling cells never need to do
    /// synchronous filesystem metadata reads merely to construct a cache key.
    static func key(url: URL, maxPixel: Int, contentIdentity: String?) -> NSString {
        if let contentIdentity, !contentIdentity.isEmpty {
            return "\(url.path)|\(maxPixel)|\(contentIdentity)" as NSString
        }
        // Generic callers without a model revision retain stale-file safety.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(maxPixel)|\(mtime)" as NSString
    }

    /// Decodes a thumbnail no larger than `maxPixel` on its longest edge.
    /// Animated sources are returned whole so `NSImageView` can still play them.
    static func makeThumbnail(url: URL, maxPixel: Int) -> DecodedThumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url).map(DecodedThumbnail.fallback)
        }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            guard let image = NSImage(contentsOf: url) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 1
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 1
            // Account for every decoded frame. The previous first-representation
            // estimate made a large GIF look like one tiny bitmap to NSCache,
            // allowing an unbounded animated-image library to occupy memory.
            let pixelsPerFrame = width.multipliedReportingOverflow(by: height)
            let allFrames = pixelsPerFrame.partialValue.multipliedReportingOverflow(by: frameCount)
            let bytes = allFrames.partialValue.multipliedReportingOverflow(by: 4)
            let cost = (pixelsPerFrame.overflow || allFrames.overflow || bytes.overflow) ? Int.max : bytes.partialValue
            return DecodedThumbnail(image: image, decodedByteCost: cost)
        }
        let options: [CFString: Any] = [
            // Always downsample from the full image so quality matches the source
            // rather than relying on a possibly-smaller embedded thumbnail.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url).map(DecodedThumbnail.fallback)
        }
        return DecodedThumbnail(
            image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
            decodedByteCost: cg.bytesPerRow * cg.height
        )
    }

    struct DecodedThumbnail {
        let image: NSImage
        let decodedByteCost: Int

        static func fallback(_ image: NSImage) -> DecodedThumbnail {
            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 1
            return DecodedThumbnail(image: image, decodedByteCost: max(1, pixels * 4))
        }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Reads only an image's pixel dimensions from its header — no pixel decode.
/// Used by the preview/pinned-note layout math, which previously full-decoded an
/// image just to measure it.
func imagePixelSize(of url: URL) -> NSSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else { return nil }
    return NSSize(width: width, height: height)
}

/// A cached, downsampled image view for grid cells. A cache hit shows instantly;
/// a miss decodes off the main thread and fades in, so a fast scroll never
/// blocks on a decode. The gray cell background behind it is the placeholder.
struct ThumbnailImageView: NSViewRepresentable {
    let url: URL
    /// The cell's on-screen size in points; the thumbnail is decoded at this
    /// size times the screen scale.
    let targetPoints: CGFloat
    /// Stable model revision (normally SHA-256). Supplying it keeps cache-key
    /// creation off the filesystem on the main thread.
    let contentIdentity: String?

    init(url: URL, targetPoints: CGFloat, contentIdentity: String? = nil) {
        self.url = url
        self.targetPoints = targetPoints
        self.contentIdentity = contentIdentity
    }

    private var maxPixel: Int {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return max(1, Int((targetPoints * scale).rounded()))
    }

    func makeNSView(context: Context) -> ThumbnailNSImageView {
        let view = ThumbnailNSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.load(url: url, maxPixel: maxPixel, contentIdentity: contentIdentity)
        return view
    }

    func updateNSView(_ view: ThumbnailNSImageView, context: Context) {
        view.animates = true
        view.load(url: url, maxPixel: maxPixel, contentIdentity: contentIdentity)
    }

    final class ThumbnailNSImageView: NSImageView {
        private var currentKey: NSString?
        /// The key of the decode currently in flight, so a re-render (e.g. a
        /// hover state change) for the same image does not start a second decode.
        private var pendingKey: NSString?
        /// Lazy grids recycle their AppKit views. Cancel work that has not
        /// started when a recycled cell is assigned a different image, so a
        /// fast scroll cannot leave the two-worker queue clogged with stale
        /// off-screen thumbnails.
        private var pendingOperation: Operation?
        private var generation = 0

        deinit { pendingOperation?.cancel() }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func load(url: URL, maxPixel: Int, contentIdentity: String?) {
            let key = ImageThumbnailCache.key(url: url, maxPixel: maxPixel, contentIdentity: contentIdentity)
            if key == currentKey, image != nil { return }
            currentKey = key

            if let cached = ImageThumbnailCache.shared.cached(for: key) {
                pendingOperation?.cancel()
                pendingOperation = nil
                pendingKey = nil
                layer?.removeAnimation(forKey: "fadeIn")
                image = cached
                return
            }
            if key == pendingKey { return }

            // Miss: show the placeholder, then decode off the main thread and
            // fade the result in.
            pendingOperation?.cancel()
            pendingKey = key
            generation += 1
            let generationAtStart = generation
            image = nil
            let keyBox = Sendify(value: key)
            let operation = BlockOperation {
                let thumbnail = ImageThumbnailCache.makeThumbnail(url: url, maxPixel: maxPixel)
                if let thumbnail {
                    ImageThumbnailCache.shared.store(thumbnail, for: keyBox.value)
                }
                let imageBox = Sendify(value: thumbnail?.image)
                Task { @MainActor [weak self] in
                    self?.apply(imageBox.value, key: keyBox.value, generation: generationAtStart)
                }
            }
            pendingOperation = operation
            ImageThumbnailCache.shared.decodeQueue.addOperation(operation)
        }

        @MainActor
        private func apply(_ loaded: NSImage?, key: NSString, generation gen: Int) {
            guard generation == gen, currentKey == key else { return }
            pendingOperation = nil
            pendingKey = nil
            guard let loaded else { return }
            image = loaded
            wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.16
            layer?.add(fade, forKey: "fadeIn")
        }
    }
}
