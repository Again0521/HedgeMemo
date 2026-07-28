import AppKit
import HedgeMemoCore
import SwiftUI
import UniformTypeIdentifiers

/// Per-application capture policy. App selection is the only throwing boundary:
/// bundle inspection errors propagate from HedgeMemoCore and are converted to a
/// visible alert here rather than being silently ignored.
struct ClipboardAppFilterSettingsView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @State private var presentedError: PresentedAppFilterError?

    var body: some View {
        SettingsSection(
            title: L10n.text("来源应用"),
            footer: footerText
        ) {
            SettingsFormRow(L10n.text("捕获模式")) {
                Picker(L10n.text("捕获模式"), selection: modeBinding) {
                    ForEach(ClipboardAppFilterMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: SettingsLayout.controlColumnWidth, alignment: .trailing)
            }

            if store.settings.resolvedAppFilterMode != .disabled {
                SettingsDivider()
                if configuredApplications.isEmpty {
                    SettingsRow {
                        Label(emptyStateText, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(
                                store.settings.resolvedAppFilterMode == .allowlist
                                    ? Color.orange
                                    : Color.secondary
                            )
                    }
                } else {
                    ForEach(configuredApplications) { application in
                        SettingsRow {
                            applicationRow(application)
                        }
                        SettingsDivider()
                    }
                }
                SettingsActionRow {
                    addApplicationMenu
                }
            }
        }
        .sheet(item: $presentedError) { error in
            UnifiedMessagePopupContent(
                title: L10n.text("无法添加应用"),
                message: error.message,
                onDismiss: { presentedError = nil }
            )
            .unifiedPopupSurface()
        }
    }

    private var configuredApplications: [ClipboardSourceApplication] {
        store.settings.appFilterApplications ?? []
    }

    private var footerText: String {
        switch store.settings.resolvedAppFilterMode {
        case .disabled:
            L10n.text("不限制复制来源。")
        case .blocklist:
            L10n.text("不会读取或保存来自列表中应用的剪贴板内容。")
        case .allowlist:
            L10n.text("只读取并保存来自列表中应用的剪贴板内容；来源未知时不会记录。")
        }
    }

    private var emptyStateText: String {
        switch store.settings.resolvedAppFilterMode {
        case .disabled:
            ""
        case .blocklist:
            L10n.text("黑名单为空，当前不会排除任何应用。")
        case .allowlist:
            L10n.text("白名单为空，当前不会记录任何应用。")
        }
    }

    private var modeBinding: Binding<ClipboardAppFilterMode> {
        Binding(
            get: { store.settings.resolvedAppFilterMode },
            set: { store.settings.appFilterMode = $0 }
        )
    }

    private var addApplicationMenu: some View {
        Menu {
            let suggestions = suggestedApplications
            ForEach(suggestions.prefix(12)) { application in
                Button {
                    store.settings.addAppFilterApplication(application)
                } label: {
                    Text(application.displayName)
                }
            }
            if !suggestions.isEmpty { Divider() }
            Button {
                chooseApplication()
            } label: {
                Label(L10n.text("选择应用…"), systemImage: "folder")
            }
        } label: {
            Label(L10n.text("添加应用…"), systemImage: "plus")
        }
    }

    private var suggestedApplications: [ClipboardSourceApplication] {
        let configured = Set(configuredApplications.map(\.stableIdentifier))
        var seen = Set<String>()
        return store.entries
            .reversed()
            .compactMap(\.sourceApplication)
            .filter {
                ($0.bundleIdentifier != nil || $0.bundleURLPath != nil)
                    && !configured.contains($0.stableIdentifier)
                    && seen.insert($0.stableIdentifier).inserted
            }
    }

    private func applicationRow(_ application: ClipboardSourceApplication) -> some View {
        HStack(spacing: 10) {
            applicationIcon(application)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .lineLimit(1)
                Text(application.bundleIdentifier ?? application.bundleURLPath ?? L10n.text("来源标识不可用"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(role: .destructive) {
                store.settings.removeAppFilterApplication(id: application.stableIdentifier)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help(L10n.text("移除"))
            .accessibilityLabel(L10n.format("移除应用格式", application.displayName))
        }
    }

    @ViewBuilder
    private func applicationIcon(_ application: ClipboardSourceApplication) -> some View {
        if let path = application.bundleURLPath,
           FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = L10n.text("添加")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let application = try ClipboardSourceApplication(bundleURL: url)
            store.settings.addAppFilterApplication(application)
        } catch {
            presentedError = PresentedAppFilterError(error: error)
        }
    }
}

private struct PresentedAppFilterError: Identifiable {
    let id = UUID()
    let message: String

    init(error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
