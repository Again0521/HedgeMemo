import AppKit
import Dispatch
import HedgeMemoCore

/// Centralizes release of rebuildable presentation caches. User content,
/// original images, GIF frames on disk, window geometry and all visual settings
/// remain untouched.
@MainActor
final class TransientMemoryCoordinator {
    private let clipboardStore: ClipboardHistoryStore
    private let memeStore: MemeStore
    private var observers: [NSObjectProtocol] = []
    private var idlePurgeWork: DispatchWorkItem?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(clipboardStore: ClipboardHistoryStore, memeStore: MemeStore) {
        self.clipboardStore = clipboardStore
        self.memeStore = memeStore
    }

    func start() {
        guard observers.isEmpty, memoryPressureSource == nil else { return }

        let applicationCenter = NotificationCenter.default
        observers.append(
            applicationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleIdlePurge() }
            }
        )
        observers.append(
            applicationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cancelIdlePurge() }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.releaseAll() }
                }
            )
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
        source.resume()
        memoryPressureSource = source
    }

    func stop() {
        cancelIdlePurge()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        let applicationCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            applicationCenter.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    func releaseAll() {
        cancelIdlePurge()
        clipboardStore.releaseTransientCaches()
        memeStore.releaseTransientCaches()
        ClipboardRuntimeCaches.removeAll()
        CodeHighlighter.releaseTransientCache()
        SourceApplicationIcon.releaseTransientCache()
        ImageThumbnailCache.shared.purgeImmediately()
    }

    private func scheduleIdlePurge(after delay: TimeInterval = 30) {
        cancelIdlePurge()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
        idlePurgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelIdlePurge() {
        idlePurgeWork?.cancel()
        idlePurgeWork = nil
    }

}
