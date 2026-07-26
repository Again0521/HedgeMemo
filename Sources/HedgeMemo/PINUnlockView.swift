import AppKit
import HedgeMemoCore
import LocalAuthentication
import SwiftUI

/// Touch ID (falling back to the login password) for unlocking a protected
/// surface.
///
/// `isAvailable` is resolved **once**, lazily, and never from inside a SwiftUI
/// body. Constructing an `LAContext` while a window's view tree is being built
/// installs LocalAuthentication's out-of-process `NSRemoteView`; that view then
/// throws from `containingWindowWillOrderOnScreen:` as the window is ordered on
/// screen, which crashed the app (SIGABRT) the moment Settings was opened.
@MainActor
enum BiometricAuthenticator {
    /// Cached because the answer cannot change while the app is running, and
    /// because probing it is exactly what must not happen during a body pass.
    private static var cachedAvailability: Bool?

    static var isAvailable: Bool {
        if let cachedAvailability { return cachedAvailability }
        var error: NSError?
        let available = LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        cachedAvailability = available
        return available
    }

    /// Warms the cache away from any view update, so the first body pass that
    /// asks is a plain boolean read.
    static func prepare() {
        guard cachedAvailability == nil else { return }
        DispatchQueue.main.async { _ = isAvailable }
    }

    static func authenticate(reason: String) async -> Bool {
        // A fresh context per attempt: reusing one caches a previous successful
        // evaluation, which would let a later unlock through without the user
        // actually authenticating again.
        let context = LAContext()
        context.localizedCancelTitle = L10n.text("取消")
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Fixed-length PIN entry drawn as dots. A zero-opacity `SecureField` behind the
/// dots keeps the real keyboard handling, focus ring behaviour and paste
/// protection that AppKit already provides, so the dots stay purely a
/// presentation layer over a normal text control.
struct PINDotsField: View {
    @Binding var pin: String
    var length: Int = PINPolicy.length
    var isFocused: FocusState<Bool>.Binding
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            SecureField("", text: Binding(
                get: { pin },
                set: { newValue in
                    // Digits only, hard-capped at `length`, so the dots can
                    // never disagree with the stored value.
                    let digits = newValue.filter(\.isNumber)
                    pin = String(digits.prefix(length))
                    if pin.count == length { onComplete() }
                }
            ))
            .textFieldStyle(.plain)
            .focused(isFocused)
            .opacity(0)
            .frame(width: dotsWidth, height: 34)

            HStack(spacing: 14) {
                ForEach(0..<length, id: \.self) { index in
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.4)
                        .background(
                            Circle().fill(index < pin.count ? Color.primary : Color.clear)
                        )
                        .frame(width: 13, height: 13)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: dotsWidth, height: 34)
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
    }

    private var dotsWidth: CGFloat { CGFloat(length) * 13 + CGFloat(length - 1) * 14 }
}

public enum PINPolicy {
    /// Fixed four digits: the entry is a dot row, so a variable length would
    /// have no way to show how much is left.
    public static let length = 4
}

/// Shown in place of a protected surface. Handles both the very first visit
/// (create a PIN) and later visits (unlock). Renders nothing about the hidden
/// content — not even how many items there are.
struct PINGateView: View {
    @ObservedObject var lockStore: AppLockStore
    let gate: AppLockStore.GateState
    let surfaceName: String

    @State private var pin = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var isAuthenticating = false
    @FocusState private var pinFocused: Bool
    @FocusState private var confirmFocused: Bool

    private var isSetup: Bool { gate == .needsSetup }

    private var biometricsEnabled: Bool {
        !isSetup && lockStore.settings.allowsBiometrics && BiometricAuthenticator.isAvailable
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isSetup ? "lock.badge.plus" : "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)

            Text(isSetup ? L10n.text("为「密码」设置 PIN 码") : L10n.format("分类已锁定格式", surfaceName))
                .font(.system(size: 13, weight: .semibold))
            Text(isSetup ? L10n.text("设置 4 位 PIN 码以保护此分类") : L10n.text("输入 PIN 码以查看此分类"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            PINDotsField(pin: $pin, isFocused: $pinFocused) {
                if isSetup { confirmFocused = true } else { submitUnlock() }
            }

            if isSetup {
                Text(L10n.text("确认 PIN 码"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                PINDotsField(pin: $confirmation, isFocused: $confirmFocused) { submitSetup() }
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if biometricsEnabled {
                Button {
                    Task { await authenticateWithBiometrics() }
                } label: {
                    Label(L10n.text("使用触控 ID"), systemImage: "touchid")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isAuthenticating)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pinFocused = true
            // Biometrics are the fast path, but only when a PIN already exists.
            if biometricsEnabled { Task { await authenticateWithBiometrics() } }
        }
        .onChange(of: pin) { _, _ in message = nil }
        .onChange(of: confirmation) { _, _ in message = nil }
    }

    private func submitUnlock() {
        guard pin.count == PINPolicy.length else { return }
        if lockStore.unlock(pin: pin) {
            pin = ""
            message = nil
        } else {
            message = L10n.text("PIN 码不正确")
            pin = ""
            pinFocused = true
        }
    }

    private func submitSetup() {
        guard pin.count == PINPolicy.length, confirmation.count == PINPolicy.length else { return }
        guard pin == confirmation else {
            message = L10n.text("两次输入的 PIN 码不一致")
            confirmation = ""
            confirmFocused = true
            return
        }
        do {
            try lockStore.setPIN(pin)
            // Creating the PIN here also unlocks this visit, so the user lands
            // on the content they were reaching for.
            lockStore.markUnlocked()
            pin = ""
            confirmation = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func authenticateWithBiometrics() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await BiometricAuthenticator.authenticate(reason: L10n.format("解锁分类原因格式", surfaceName)) {
            lockStore.markUnlocked()
        }
    }
}
