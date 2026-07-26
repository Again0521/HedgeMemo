import Foundation

/// When a previously unlocked session falls back to locked.
///
/// Locking the Mac always re-locks, in every mode — nobody is surprised by
/// their passwords being protected again after they locked their screen. The
/// choice here is therefore whether there is *also* an idle timeout on top.
public enum AppLockTiming: String, Codable, CaseIterable, Sendable {
    /// Screen lock only; no idle timeout.
    case onScreenLock
    case idle5
    case idle15
    case idle30

    /// How long unused content may stay unlocked, or nil for "no idle timeout".
    public var idleInterval: TimeInterval? {
        switch self {
        case .onScreenLock: nil
        case .idle5: 5 * 60
        case .idle15: 15 * 60
        case .idle30: 30 * 60
        }
    }

    public var displayName: String {
        switch self {
        case .onScreenLock: L10n.text("当电脑锁定后")
        case .idle5: L10n.text("当未用 5 分钟后")
        case .idle15: L10n.text("当未用 15 分钟后")
        case .idle30: L10n.text("当未用 30 分钟后")
        }
    }
}

public struct AppLockSettings: Codable, Equatable, Sendable {
    public var timing: AppLockTiming
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
        timing: AppLockTiming = .onScreenLock,
        lockedCategoryKeys: [String]? = nil,
        allowsBiometrics: Bool = true,
        capturesPasswords: Bool = false
    ) {
        self.timing = timing
        self.lockedCategoryKeys = lockedCategoryKeys
            ?? [ClipboardCategoryKey.builtin(.password).storageValue]
        self.allowsBiometrics = allowsBiometrics
        self.capturesPasswords = capturesPasswords
        normalize()
    }

    public mutating func normalize() {
        // De-duplicate while keeping order stable for the settings list.
        var seen = Set<String>()
        lockedCategoryKeys = lockedCategoryKeys.filter { seen.insert($0).inserted }
    }

    /// There is no separate master switch: a category is locked exactly when
    /// the user has selected it. One source of truth avoids the state where the
    /// lock is "off" but categories still look selected.
    public func isCategoryLocked(_ key: ClipboardCategoryKey) -> Bool {
        lockedCategoryKeys.contains(key.storageValue)
    }

    public mutating func setCategory(_ key: ClipboardCategoryKey, locked: Bool) {
        setLocked(key.storageValue, locked)
    }

    /// The meme panel is a lockable surface too, but it is not a clipboard
    /// category, so it gets a reserved storage value that can never collide with
    /// a built-in name or a `custom:<uuid>` key.
    public static let memePanelStorageKey = "panel:meme"

    public var locksMemePanel: Bool {
        lockedCategoryKeys.contains(Self.memePanelStorageKey)
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
        guard let unlockedAt else { return false }
        guard let interval = settings.timing.idleInterval else { return true }
        let reference = lastUsedAt ?? unlockedAt
        return now.timeIntervalSince(reference) < interval
    }

    /// A locked category must never leak its rows through search or the quick
    /// ⌘1–9 slots either, so callers filter entries with this.
    public static func hidesEntry(
        _ entry: ClipboardEntry,
        settings: AppLockSettings,
        customCategories: [CustomClipboardCategory],
        isUnlocked: Bool
    ) -> Bool {
        guard !isUnlocked else { return false }
        return settings.lockedCategoryKeys
            .compactMap(ClipboardCategoryKey.init(storageValue:))
            .contains { entry.matches(key: $0, customCategories: customCategories) }
    }
}
