import Foundation

/// When a previously unlocked session falls back to locked.
public enum AppLockTiming: String, Codable, CaseIterable, Sendable {
    /// Re-lock as soon as the clipboard panel closes.
    case onPanelClose
    /// Re-lock after a period of not being used.
    case afterIdle
    /// Stay unlocked until the Mac sleeps or the app quits.
    case onSleepOrQuit

    public var displayName: String {
        switch self {
        case .onPanelClose: L10n.text("关闭面板后立即锁定")
        case .afterIdle: L10n.text("闲置一段时间后锁定")
        case .onSleepOrQuit: L10n.text("睡眠或退出后锁定")
        }
    }
}

public struct AppLockSettings: Codable, Equatable, Sendable {
    public static let idleMinuteChoices = [1, 2, 5, 10, 15, 30, 60]

    /// Master switch. With no PIN set this stays false, so the lock can never
    /// strand the user out of their own history.
    public var isEnabled: Bool
    public var timing: AppLockTiming
    public var idleMinutes: Int
    /// Storage values of the categories that require unlocking.
    public var lockedCategoryKeys: [String]
    public var allowsBiometrics: Bool
    /// Whether concealed clipboard content (password managers mark copies with
    /// `org.nspasteboard.ConcealedType`) is recorded at all. Default false keeps
    /// the privacy behaviour introduced in 1.2.0: passwords are simply not
    /// stored. Turning it on routes them into the locked 密码 category, where
    /// their text is encrypted at rest.
    public var capturesPasswords: Bool

    public init(
        isEnabled: Bool = false,
        timing: AppLockTiming = .onPanelClose,
        idleMinutes: Int = 5,
        lockedCategoryKeys: [String]? = nil,
        allowsBiometrics: Bool = true,
        capturesPasswords: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.timing = timing
        self.idleMinutes = idleMinutes
        self.lockedCategoryKeys = lockedCategoryKeys
            ?? [ClipboardCategoryKey.builtin(.password).storageValue]
        self.allowsBiometrics = allowsBiometrics
        self.capturesPasswords = capturesPasswords
        normalize()
    }

    public mutating func normalize() {
        idleMinutes = Self.idleMinuteChoices.min { abs($0 - idleMinutes) < abs($1 - idleMinutes) } ?? 5
        // De-duplicate while keeping order stable for the settings list.
        var seen = Set<String>()
        lockedCategoryKeys = lockedCategoryKeys.filter { seen.insert($0).inserted }
    }

    public func isCategoryLocked(_ key: ClipboardCategoryKey) -> Bool {
        isEnabled && lockedCategoryKeys.contains(key.storageValue)
    }

    public mutating func setCategory(_ key: ClipboardCategoryKey, locked: Bool) {
        setLocked(key.storageValue, locked)
    }

    /// The meme panel is a lockable surface too, but it is not a clipboard
    /// category, so it gets a reserved storage value that can never collide with
    /// a built-in name or a `custom:<uuid>` key.
    public static let memePanelStorageKey = "panel:meme"

    public var locksMemePanel: Bool {
        isEnabled && lockedCategoryKeys.contains(Self.memePanelStorageKey)
    }

    public mutating func setMemePanelLocked(_ locked: Bool) {
        setLocked(Self.memePanelStorageKey, locked)
    }

    private mutating func setLocked(_ storageValue: String, _ locked: Bool) {
        if locked {
            guard !lockedCategoryKeys.contains(storageValue) else { return }
            lockedCategoryKeys.append(storageValue)
        } else {
            lockedCategoryKeys.removeAll { $0 == storageValue }
        }
    }
}

/// Pure decisions about when a session should fall back to locked, kept out of
/// the store so they can be exercised without a running app.
public enum AppLockPolicy {
    /// Whether an unlocked session is still valid.
    public static func remainsUnlocked(
        settings: AppLockSettings,
        unlockedAt: Date?,
        lastUsedAt: Date?,
        now: Date
    ) -> Bool {
        guard settings.isEnabled else { return true }
        guard unlockedAt != nil else { return false }
        switch settings.timing {
        case .onPanelClose:
            // Panel close is an explicit event; nothing time-based expires it.
            return true
        case .afterIdle:
            let reference = lastUsedAt ?? unlockedAt ?? now
            return now.timeIntervalSince(reference) < Double(settings.idleMinutes) * 60
        case .onSleepOrQuit:
            return true
        }
    }

    /// Whether closing the clipboard panel should re-lock.
    public static func locksOnPanelClose(_ settings: AppLockSettings) -> Bool {
        settings.isEnabled && settings.timing == .onPanelClose
    }

    /// Whether the machine going to sleep should re-lock.
    public static func locksOnSleep(_ settings: AppLockSettings) -> Bool {
        settings.isEnabled && settings.timing != .onPanelClose
    }

    /// A locked category must never leak its rows through search or the quick
    /// ⌘1–9 slots either, so callers filter entries with this.
    public static func hidesEntry(
        _ entry: ClipboardEntry,
        settings: AppLockSettings,
        customCategories: [CustomClipboardCategory],
        isUnlocked: Bool
    ) -> Bool {
        guard settings.isEnabled, !isUnlocked else { return false }
        return settings.lockedCategoryKeys
            .compactMap(ClipboardCategoryKey.init(storageValue:))
            .contains { entry.matches(key: $0, customCategories: customCategories) }
    }
}
