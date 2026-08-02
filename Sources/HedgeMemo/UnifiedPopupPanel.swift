import AppKit
import HedgeMemoCore
import SwiftUI

/// AppKit owns only the modal event loop. All appearance and input state remain
/// in SwiftUI so standalone prompts use the same material and control language
/// as the rest of HedgeMemo.
@MainActor
final class UnifiedPopupSession: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private var finished = false

    init(title: String, size: NSSize) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
    }

    func present() {
        defer { TransientPanelLifetime.release(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        TextCompletionCrashGuard.prepareToOrderOnScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: panel)
    }

    func finish(_ response: NSApplication.ModalResponse = .cancel) {
        guard !finished else { return }
        finished = true
        TextCompletionCrashGuard.finishActiveTextSessions(in: [panel])
        panel.orderOut(nil)
        NSApp.stopModal(withCode: response)
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

@MainActor
enum UnifiedPopupPanel {
    static func showMessage(
        title: String,
        message: String,
        systemImage: String = "exclamationmark.triangle"
    ) {
        let session = UnifiedPopupSession(
            title: title,
            size: NSSize(width: 400, height: 210)
        )
        let content = UnifiedMessagePopupContent(
            title: title,
            message: message,
            systemImage: systemImage,
            onDismiss: { session.finish(.OK) }
        )
        PanelMaterialHost.install(content, in: session.panel, cornerRadius: 14)
        session.present()
    }

    static func requestText(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String = "",
        confirmationTitle: String,
        onCompletion: @escaping @MainActor (String?) -> Void
    ) {
        // Callers commonly arrive here from a SwiftUI Button action or an
        // AppKit mouseUp implementation. Entering runModal before that callback
        // returns leaves the originating control in possession of the current
        // mouse sequence, so the new panel's buttons look enabled but cannot
        // receive ordinary clicks. Defer one main-run-loop turn so the source
        // click finishes before the modal event loop begins.
        DispatchQueue.main.async {
            let result = runTextRequest(
                title: title,
                message: message,
                placeholder: placeholder,
                initialValue: initialValue,
                confirmationTitle: confirmationTitle
            )
            onCompletion(result)
        }
    }

    /// Returns true for the destructive confirmation, false for the explicit
    /// non-destructive choice, and nil when the window itself is closed.
    static func requestConfirmation(
        title: String,
        message: String,
        systemImage: String,
        declineTitle: String,
        confirmationTitle: String,
        onCompletion: @escaping @MainActor (Bool?) -> Void
    ) {
        // Match text requests: let the Toggle's mouseUp finish before entering
        // AppKit's modal event loop so both buttons receive their first click.
        DispatchQueue.main.async {
            let result = runConfirmationRequest(
                title: title,
                message: message,
                systemImage: systemImage,
                declineTitle: declineTitle,
                confirmationTitle: confirmationTitle
            )
            onCompletion(result)
        }
    }

    private static func runConfirmationRequest(
        title: String,
        message: String,
        systemImage: String,
        declineTitle: String,
        confirmationTitle: String
    ) -> Bool? {
        let session = UnifiedPopupSession(
            title: title,
            size: NSSize(width: 420, height: 208)
        )
        var result: Bool?
        let content = UnifiedConfirmationPopupContent(
            title: title,
            message: message,
            systemImage: systemImage,
            declineTitle: declineTitle,
            confirmationTitle: confirmationTitle,
            onDecline: {
                result = false
                session.finish(.cancel)
            },
            onConfirm: {
                result = true
                session.finish(.OK)
            }
        )
        PanelMaterialHost.install(content, in: session.panel, cornerRadius: 14)
        session.present()
        return result
    }

    private static func runTextRequest(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String,
        confirmationTitle: String
    ) -> String? {
        let session = UnifiedPopupSession(
            title: title,
            size: NSSize(width: 400, height: 182)
        )
        var result: String?
        let content = UnifiedTextInputPopupContent(
            title: title,
            message: message,
            placeholder: placeholder,
            initialValue: initialValue,
            confirmationTitle: confirmationTitle,
            onCancel: { session.finish() },
            onConfirm: {
                result = $0
                session.finish(.OK)
            }
        )
        PanelMaterialHost.install(content, in: session.panel, cornerRadius: 14)
        session.present()
        return result
    }
}

struct UnifiedConfirmationPopupContent: View {
    let title: String
    let message: String
    let systemImage: String
    let declineTitle: String
    let confirmationTitle: String
    let onDecline: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.headline)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(declineTitle, action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Button(confirmationTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 420)
        .frame(minHeight: 188)
    }
}

struct UnifiedMessagePopupContent: View {
    let title: String
    let message: String
    var systemImage = "exclamationmark.triangle"
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.headline)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(L10n.text("好"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 400)
        .frame(minHeight: 190)
    }
}

private struct UnifiedTextInputPopupContent: View {
    let title: String
    let message: String
    let placeholder: String
    let confirmationTitle: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var value: String
    @FocusState private var isFocused: Bool

    init(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String,
        confirmationTitle: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirmationTitle = confirmationTitle
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $value)
                .disablesRemoteTextCompletion()
                .focused($isFocused)
            HStack {
                Spacer()
                Button(L10n.text("取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmationTitle) {
                    onConfirm(value)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }
}
