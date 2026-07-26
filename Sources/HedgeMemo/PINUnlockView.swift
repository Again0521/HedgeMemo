import AppKit
import HedgeMemoCore
import LocalAuthentication
import SwiftUI

/// Touch ID (falling back to the login password) for unlocking a locked
/// clipboard category. `LAContext` is created per attempt: reusing one caches a
/// previous successful evaluation, which would let a second unlock through
/// without the user actually authenticating again.
@MainActor
enum BiometricAuthenticator {
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = L10n.text("取消")
        // `.deviceOwnerAuthentication` keeps the system's own password fallback
        // available when a finger is not recognized.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Shown in place of a locked category's list. Deliberately renders nothing
/// about the hidden entries — not even how many there are.
struct PINUnlockView: View {
    @ObservedObject var lockStore: AppLockStore
    let categoryName: String

    @State private var pin = ""
    @State private var showsError = false
    @State private var isAuthenticating = false
    @FocusState private var isFieldFocused: Bool

    private var biometricsEnabled: Bool {
        lockStore.settings.allowsBiometrics && BiometricAuthenticator.isAvailable
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(L10n.format("分类已锁定格式", categoryName))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.text("输入 PIN 码以查看此分类"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            SecureField(L10n.text("PIN 码"), text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .multilineTextAlignment(.center)
                .focused($isFieldFocused)
                .onSubmit(submit)
                .onChange(of: pin) { _, _ in showsError = false }

            if showsError {
                Text(L10n.text("PIN 码不正确"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button(L10n.text("解锁"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty)
                if biometricsEnabled {
                    Button {
                        Task { await authenticateWithBiometrics() }
                    } label: {
                        Label(L10n.text("使用触控 ID"), systemImage: "touchid")
                    }
                    .disabled(isAuthenticating)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isFieldFocused = true
            // Offer the biometric prompt straight away: that is the fast path,
            // and the PIN field stays focused behind it if the user cancels.
            if biometricsEnabled { Task { await authenticateWithBiometrics() } }
        }
    }

    private func submit() {
        guard !pin.isEmpty else { return }
        if lockStore.unlock(pin: pin) {
            pin = ""
            showsError = false
        } else {
            showsError = true
            pin = ""
        }
    }

    private func authenticateWithBiometrics() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let reason = L10n.format("解锁分类原因格式", categoryName)
        if await BiometricAuthenticator.authenticate(reason: reason) {
            lockStore.markUnlocked()
        }
    }
}
