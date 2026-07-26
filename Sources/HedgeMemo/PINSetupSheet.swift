import HedgeMemoCore
import SwiftUI

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
    @FocusState private var pinFocused: Bool
    @FocusState private var confirmFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        pin.count == PINPolicy.length && pin == confirmation
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.text(lockStore.hasPIN ? "修改 PIN 码…" : "设置 PIN 码…"))
                .font(.headline)

            Text(L10n.text("新建 PIN 码"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            PINDotsField(pin: $pin, isFocused: $pinFocused) { confirmFocused = true }

            Text(L10n.text("确认 PIN 码"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            PINDotsField(pin: $confirmation, isFocused: $confirmFocused) { save() }

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
                Button(L10n.text("保存"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { pinFocused = true }
        .onChange(of: pin) { _, _ in errorMessage = nil }
        .onChange(of: confirmation) { _, _ in errorMessage = nil }
    }

    private func save() {
        guard pin.count == PINPolicy.length else {
            errorMessage = L10n.text("PIN 码需为 4 位数字")
            return
        }
        guard pin == confirmation else {
            errorMessage = L10n.text("两次输入的 PIN 码不一致")
            confirmation = ""
            confirmFocused = true
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
