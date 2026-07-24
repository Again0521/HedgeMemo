import Foundation
import HedgeMemoCore
import ServiceManagement

/// Small wrapper around the system-managed login-item service. Keeping the
/// status in one observable object lets Settings reflect approval changes made
/// in System Settings without persisting a second, potentially stale flag.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = nil
        case .requiresApproval:
            isEnabled = true
            statusMessage = L10n.text("登录项等待系统设置批准")
        case .notRegistered, .notFound:
            isEnabled = false
            statusMessage = nil
        @unknown default:
            isEnabled = false
            statusMessage = L10n.text("无法读取登录项状态")
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusMessage = L10n.format("无法更新登录项格式", error.localizedDescription)
        }
    }
}
