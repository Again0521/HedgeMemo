import AppKit
import SwiftUI

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
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let window = notification.object as? NSWindow else { return }
                // End editing while the field editor still belongs to its
                // original window. Detaching SwiftUI first can strand Safari's
                // completion NSRemoteView with no containing window.
                MainActor.assumeIsolated {
                    Self.finishActiveTextSessions(in: [window])
                }
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
        // A nil semantic content type prevents SafariPlatformSupport from
        // attaching its credential / one-time-code NSRemoteView to transient
        // search and PIN fields. The remote view can otherwise survive the
        // panel that created it and throw when a later panel is ordered.
        field.contentType = nil
        if #available(macOS 15.2, *) { field.allowsWritingTools = false }
        if let editor = field.currentEditor() as? NSTextView {
            disableRemoteCompletion(for: editor)
        }
    }

    static func disableRemoteCompletion(for textView: NSTextView) {
        textView.isAutomaticTextCompletionEnabled = false
        textView.contentType = nil
    }

    /// Must run before an AppKit/SwiftUI window is ordered on screen.
    ///
    /// `didBecomeKey` is too late for this failure mode: ViewBridge validates
    /// completion remote views during `makeKeyAndOrderFront`. A field editor
    /// retained by a disappearing popover can therefore abort the process
    /// before any key-window notification is delivered. End those old editing
    /// sessions first, materialize the destination hierarchy, and disable
    /// completion there before AppKit starts its order-on-screen transaction.
    static func prepareToOrderOnScreen(
        _ destination: NSWindow,
        existingWindows: [NSWindow]? = nil
    ) {
        finishActiveTextSessions(in: existingWindows ?? NSApp.windows)
        destination.contentView?.layoutSubtreeIfNeeded()
        disableRemoteCompletion(in: destination)
    }

    static func finishActiveTextSessions(in windows: [NSWindow]? = nil) {
        for window in windows ?? NSApp.windows {
            disableRemoteCompletion(in: window)
            guard window.firstResponder is NSTextView else { continue }
            // Ending editing commits the current SwiftUI/AppKit binding before
            // another window appears and tears down its completion ViewBridge
            // session while the editor still has the correct containing window.
            window.makeFirstResponder(nil)
        }
    }
}

/// Configures SwiftUI-owned text controls before focus. Their exact SwiftUI
/// styling and layout remain untouched; the invisible bridge only reaches the
/// native window to disable unrelated completion services.
private struct RemoteCompletionDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(RemoteCompletionConfigurationBridge())
    }
}

private struct RemoteCompletionConfigurationBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoteCompletionConfigurationView {
        RemoteCompletionConfigurationView()
    }

    func updateNSView(_ view: RemoteCompletionConfigurationView, context: Context) {
        view.configureContainingWindow()
    }
}

private final class RemoteCompletionConfigurationView: NSView {
    private weak var configuredWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        configuredWindow = nil
        if let newWindow { TextCompletionCrashGuard.disableRemoteCompletion(in: newWindow) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureContainingWindow()
    }

    func configureContainingWindow() {
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window
        TextCompletionCrashGuard.disableRemoteCompletion(in: window)
        // SwiftUI can finish creating a sibling NSTextField after this marker
        // joins the hierarchy. Recheck once before the user can focus it.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            TextCompletionCrashGuard.disableRemoteCompletion(in: window)
        }
    }
}

extension View {
    func disablesRemoteTextCompletion() -> some View {
        modifier(RemoteCompletionDisabledModifier())
    }
}
