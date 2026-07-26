import HedgeMemoCore
import SwiftUI

/// Proves the user knows the current PIN before Settings will let them change
/// or remove it. Reuses the same gate the locked categories show, so the entry
/// experience (dots, Touch ID, error copy) is identical everywhere.
struct PINVerifySheet: View {
    @ObservedObject var lockStore: AppLockStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            PINGateView(
                lockStore: lockStore,
                gate: .needsUnlock,
                surfaceName: L10n.text("设置")
            )
            Button(L10n.text("取消")) { dismiss() }
        }
        .padding(.vertical, 16)
        .frame(width: 320)
        // `unlockedAt` is the published signal; a successful PIN entry or Touch
        // ID both set it, so this covers either route out of the sheet.
        .onChange(of: lockStore.unlockedAt) { _, unlockedAt in
            if unlockedAt != nil { dismiss() }
        }
    }
}

/// Creates or replaces the PIN from Settings. Requires the same four digits
/// twice so a typo cannot silently lock the user out of their own content.
struct PINSetupSheet: View {
    @ObservedObject var lockStore: AppLockStore
    /// Called with true once a PIN exists, so the caller can enable the lock in
    /// the same gesture that created it.
    let onFinished: (Bool) -> Void

    @State private var pin = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var step: PINSetupStep = .newPIN
    @FocusState private var pinFocused: Bool
    @FocusState private var confirmFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        confirmation.count == PINPolicy.length
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.text(lockStore.hasPIN ? "修改 PIN 码…" : "设置 PIN 码…"))
                .font(.headline)

            Text(L10n.text(step == .newPIN ? "新建 PIN 码" : "确认 PIN 码"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if step == .newPIN {
                PINDotsField(pin: $pin, isFocused: $pinFocused) {}
            } else {
                PINDotsField(pin: $confirmation, isFocused: $confirmFocused) {}
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(L10n.text("密码内容会加密保存，仅在复制时解密；列表中始终以隐藏形式显示。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.text("取消")) {
                    onFinished(false)
                    dismiss()
                }
                if step == .newPIN {
                    Button(L10n.text("继续"), action: showConfirmation)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pin.count != PINPolicy.length)
                } else {
                    Button(L10n.text("返回"), action: showNewPIN)
                    Button(L10n.text("保存"), action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { pinFocused = true }
        .onChange(of: pin) { _, value in
            if !value.isEmpty { errorMessage = nil }
        }
        .onChange(of: confirmation) { _, value in
            if !value.isEmpty { errorMessage = nil }
        }
    }

    private func showConfirmation() {
        guard pin.count == PINPolicy.length else {
            errorMessage = L10n.text("PIN 码需为 4 位数字")
            return
        }
        step = .confirmation
        errorMessage = nil
        pinFocused = false
        DispatchQueue.main.async { confirmFocused = true }
    }

    private func showNewPIN() {
        step = .newPIN
        confirmation = ""
        errorMessage = nil
        confirmFocused = false
        DispatchQueue.main.async { pinFocused = true }
    }

    private func save() {
        guard pin.count == PINPolicy.length else {
            errorMessage = L10n.text("PIN 码需为 4 位数字")
            return
        }
        guard pin == confirmation else {
            errorMessage = L10n.text("两次输入的 PIN 码不一致")
            pin = ""
            confirmation = ""
            step = .newPIN
            DispatchQueue.main.async { pinFocused = true }
            return
        }
        do {
            try lockStore.setPIN(pin)
            onFinished(true)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
