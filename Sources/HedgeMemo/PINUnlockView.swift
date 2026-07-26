import AppKit
import HedgeMemoCore
import LocalAuthentication
import SwiftUI

/// Thread-safe home for the resolved Touch ID availability.
///
/// It lives outside `BiometricAuthenticator` on purpose: that enum is
/// `@MainActor`, so its static storage — including a plain `NSLock` — is
/// main-actor isolated and cannot be touched from the background probe. A
/// self-synchronising `Sendable` box is readable from either side without
/// weakening the isolation of anything else.
private final class BiometricAvailabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    func resolve(_ newValue: Bool) {
        lock.lock()
        resolved = newValue
        lock.unlock()
    }
}

/// A `let` global of a `Sendable` type carries no actor isolation, which is
/// exactly what both the main-actor readers and the background writer need.
private let biometricAvailability = BiometricAvailabilityBox()

/// Touch ID (falling back to the login password) for unlocking a protected
/// surface.
///
/// Availability is resolved **once**, off the main thread, and never from inside
/// a SwiftUI body: constructing an `LAContext` while a window's view tree is
/// being built installs LocalAuthentication's out-of-process `NSRemoteView`,
/// which then throws from `containingWindowWillOrderOnScreen:` as the window is
/// ordered on screen — a SIGABRT the moment Settings opened.
@MainActor
enum BiometricAuthenticator {
    /// Defaults to false until the background probe lands. Settings only uses it
    /// to enable the Touch ID toggle, which corrects itself as soon as the probe
    /// finishes — far better than blocking the window's first frame.
    ///
    /// `canEvaluatePolicy` is not a cheap accessor: it talks to `biometrickitd`
    /// over XPC and can block for a noticeable fraction of a second on the first
    /// call, which is what made opening Settings stutter.
    static var isAvailable: Bool { biometricAvailability.value ?? false }

    /// Resolves availability off the main thread. Called once at launch.
    static func prepare() {
        guard biometricAvailability.value == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            var error: NSError?
            let available = LAContext().canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )
            biometricAvailability.resolve(available)
        }
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

    /// Too many wrong PINs: entry is refused for a while. Touch ID stays
    /// available throughout — it proves the actual device owner is present and
    /// cannot be guessed, so the anti-brute-force penalty does not apply to it.
    private var isCoolingDown: Bool { !isSetup && lockStore.isCoolingDown }

    private static func countdown(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

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

            if isCoolingDown {
                // Ticks only while the penalty is running, so no timer is left
                // alive once entry is available again.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = AppLockPolicy.cooldownRemaining(
                        until: lockStore.cooldownUntil,
                        now: context.date
                    )
                    Text(L10n.format("PIN 冷却格式", Self.countdown(remaining)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.red)
                }
            } else {
                PINDotsField(pin: $pin, isFocused: $pinFocused) {
                    if isSetup { confirmFocused = true } else { submitUnlock() }
                }
            }

            if isSetup {
                Text(L10n.text("确认 PIN 码"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                PINDotsField(pin: $confirmation, isFocused: $confirmFocused) { submitSetup() }
            }

            if let message, !isCoolingDown {
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
        // Height is owned by the caller (the panel reserves a fixed gate
        // height). Claiming `maxHeight: .infinity` here fought that reservation
        // and made the card resize twice while it settled.
        .frame(maxWidth: .infinity)
        .onAppear {
            pinFocused = !isCoolingDown
            // Deliberately no automatic Touch ID prompt here. `evaluatePolicy`
            // presents its dialog as an out-of-process sheet on the containing
            // window; firing it from `onAppear` raced that window's own
            // presentation, and the remote view then threw from
            // `containingWindowWillOrderOnScreen:` — an ObjC exception that
            // aborted the process. The user taps 使用触控 ID instead, which is
            // always after the window is fully on screen.
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
            let left = AppLockPolicy.maxFailedAttempts - lockStore.failedAttempts
            message = lockStore.isCoolingDown || left <= 0
                ? L10n.text("PIN 码不正确")
                : L10n.format("PIN 剩余次数格式", left)
            pin = ""
            pinFocused = !lockStore.isCoolingDown
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
