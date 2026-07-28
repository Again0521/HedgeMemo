import AppKit

/// Prevents AppKit's system completion view service from outliving one of our
/// short-lived panels.
///
/// On macOS 27 a completion remote view can remain registered after its text
/// field disappears. When the display wakes, AppKit orders the status-item
/// window on screen and ViewBridge sends that notification to the stale remote
/// view as well. The framework then raises `NSInternalInconsistencyException`
/// because the completion view expected no containing window.
///
/// HedgeMemo's inputs are searches, category rules, a PIN, or editors with
/// their own inline completion, so disabling the unrelated system completion
/// service loses no app behavior and leaves rendering unchanged.
@MainActor
final class TextCompletionCrashGuard {
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor in
                    Self.disableRemoteCompletion(in: window)
                    // SwiftUI may install a field editor during the same window
                    // transaction, after didBecomeKey. Recheck once it settles.
                    await Task.yield()
                    Self.disableRemoteCompletion(in: window)
                }
            }
        )
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSControl.textDidBeginEditingNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let field = notification.object as? NSTextField else { return }
                Task { @MainActor in Self.disableRemoteCompletion(for: field) }
            }
        )
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSText.didBeginEditingNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let textView = notification.object as? NSTextView else { return }
                Task { @MainActor in Self.disableRemoteCompletion(for: textView) }
            }
        )

        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            notificationObservers.append(
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    Task { @MainActor in Self.finishActiveTextSessions() }
                }
            )
        }
    }

    static func disableRemoteCompletion(in window: NSWindow) {
        if let contentView = window.contentView {
            disableRemoteCompletion(in: contentView)
        }
        if let editor = window.firstResponder as? NSTextView {
            disableRemoteCompletion(for: editor)
        }
    }

    static func disableRemoteCompletion(in view: NSView) {
        if let field = view as? NSTextField {
            disableRemoteCompletion(for: field)
        }
        if let textView = view as? NSTextView {
            disableRemoteCompletion(for: textView)
        }
        for subview in view.subviews {
            disableRemoteCompletion(in: subview)
        }
    }

    static func disableRemoteCompletion(for field: NSTextField) {
        field.isAutomaticTextCompletionEnabled = false
        if let editor = field.currentEditor() as? NSTextView {
            disableRemoteCompletion(for: editor)
        }
    }

    static func disableRemoteCompletion(for textView: NSTextView) {
        textView.isAutomaticTextCompletionEnabled = false
    }

    private static func finishActiveTextSessions() {
        for window in NSApp.windows where window.firstResponder is NSTextView {
            // Ending editing commits the current SwiftUI/AppKit binding before
            // sleep and tears down any completion ViewBridge session.
            window.makeFirstResponder(nil)
        }
    }
}
