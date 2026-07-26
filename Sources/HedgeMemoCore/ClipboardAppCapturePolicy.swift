import Foundation

/// Stable metadata for the application that owned the foreground when a
/// pasteboard change was observed. Bundle identifiers are the primary identity;
/// path and display name are retained as fallbacks for unsigned/local apps.
public struct ClipboardSourceApplication: Codable, Hashable, Identifiable, Sendable {
    public let bundleIdentifier: String?
    public let displayName: String
    public let bundleURLPath: String?

    public init(
        bundleIdentifier: String?,
        displayName: String,
        bundleURLPath: String? = nil
    ) {
        let trimmedIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = bundleURLPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = trimmedIdentifier?.isEmpty == false ? trimmedIdentifier : nil
        self.displayName = trimmedName
        self.bundleURLPath = trimmedPath?.isEmpty == false ? trimmedPath : nil
    }

    public init(bundleURL: URL) throws {
        guard let bundle = Bundle(url: bundleURL) else {
            throw ClipboardSourceApplicationError.notApplicationBundle(bundleURL)
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardSourceApplicationError.missingApplicationName(bundleURL)
        }
        self.init(
            bundleIdentifier: bundle.bundleIdentifier,
            displayName: name,
            bundleURLPath: bundleURL.standardizedFileURL.path
        )
    }

    /// A deterministic key suitable for settings, filtering and SwiftUI IDs.
    /// The name fallback keeps legacy entries useful even though it is less
    /// reliable than a bundle identifier or path.
    public var stableIdentifier: String {
        if let bundleIdentifier {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        if let bundleURLPath {
            return "path:\(URL(fileURLWithPath: bundleURLPath).standardizedFileURL.path.lowercased())"
        }
        return "name:\(displayName.lowercased())"
    }

    public var id: String { stableIdentifier }

    public func matches(_ other: ClipboardSourceApplication) -> Bool {
        stableIdentifier == other.stableIdentifier
    }

    public static let hedgeMemo = ClipboardSourceApplication(
        bundleIdentifier: "com.hedgememo.app",
        displayName: "HedgeMemo"
    )
}

public enum ClipboardSourceApplicationError: LocalizedError, Equatable {
    case notApplicationBundle(URL)
    case missingApplicationName(URL)

    public var errorDescription: String? {
        switch self {
        case .notApplicationBundle:
            L10n.text("所选项目不是有效的 macOS 应用。")
        case .missingApplicationName:
            L10n.text("无法读取所选应用的信息。")
        }
    }
}

public enum ClipboardAppFilterMode: String, Codable, CaseIterable, Sendable {
    case disabled
    case blocklist
    case allowlist

    public var displayName: String {
        switch self {
        case .disabled: L10n.text("不限制")
        case .blocklist: L10n.text("黑名单")
        case .allowlist: L10n.text("白名单")
        }
    }
}

public enum ClipboardAppCapturePolicy {
    /// Unknown sources are allowed by a blocklist and rejected by an allowlist.
    /// This makes both modes conservative in the direction their names promise.
    public static func allows(
        source: ClipboardSourceApplication?,
        mode: ClipboardAppFilterMode,
        applications: [ClipboardSourceApplication]
    ) -> Bool {
        switch mode {
        case .disabled:
            return true
        case .blocklist:
            guard let source else { return true }
            return !applications.contains { $0.matches(source) }
        case .allowlist:
            guard let source else { return false }
            return applications.contains { $0.matches(source) }
        }
    }
}
