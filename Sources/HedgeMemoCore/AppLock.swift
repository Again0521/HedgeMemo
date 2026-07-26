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
    /// `org.nspasteboard.ConcealedType`) is recorded at all.
    ///
    /// On by default: such copies land in the 密码 category, which is always
    /// PIN-gated and whose text is encrypted at rest, so recording them does not
    /// expose them the way an ordinary history entry would. Switching this off
    /// restores the 1.2.0 behaviour of not storing them at all.
    public var capturesPasswords: Bool

    public init(
        timing: AppLockTiming = .onScreenLock,
        lockedCategoryKeys: [String]? = nil,
        allowsBiometrics: Bool = true,
        capturesPasswords: Bool = true
    ) {
        self.timing = timing
        self.lockedCategoryKeys = lockedCategoryKeys
            ?? [ClipboardCategoryKey.builtin(.password).storageValue]
        self.allowsBiometrics = allowsBiometrics
        self.capturesPasswords = capturesPasswords
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case timing
        case lockedCategoryKeys
        case allowsBiometrics
        case capturesPasswords
    }

    /// Decode each preference independently so adding a setting in a later
    /// release does not make the whole saved security configuration unreadable.
    /// Synthesized `Decodable` rejects an older payload as soon as one new,
    /// non-optional key is absent and would silently reset every lock choice.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timing = try values.decodeIfPresent(AppLockTiming.self, forKey: .timing) ?? .onScreenLock
        lockedCategoryKeys = try values.decodeIfPresent([String].self, forKey: .lockedCategoryKeys)
            ?? [ClipboardCategoryKey.builtin(.password).storageValue]
        allowsBiometrics = try values.decodeIfPresent(Bool.self, forKey: .allowsBiometrics) ?? true
        capturesPasswords = try values.decodeIfPresent(Bool.self, forKey: .capturesPasswords) ?? true
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
    /// Wrong PINs tolerated before entry is refused for a while. A 4-digit PIN
    /// is only ten thousand combinations, so without a penalty an attacker at an
    /// unattended Mac could simply keep typing.
    public static let maxFailedAttempts = 5
    public static let cooldownDuration: TimeInterval = 10 * 60

    /// How long PIN entry stays refused, or zero once the penalty has expired.
    public static func cooldownRemaining(until: Date?, now: Date) -> TimeInterval {
        guard let until else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    public static func isCoolingDown(until: Date?, now: Date) -> Bool {
        cooldownRemaining(until: until, now: now) > 0
    }

    /// The state after a wrong PIN: either one more strike, or the start of a
    /// cooldown with the counter reset so the next penalty needs five fresh
    /// failures rather than triggering on every subsequent attempt.
    public static func afterFailedAttempt(
        failedAttempts: Int,
        now: Date
    ) -> (failedAttempts: Int, cooldownUntil: Date?) {
        let attempts = failedAttempts + 1
        guard attempts >= maxFailedAttempts else { return (attempts, nil) }
        return (0, now.addingTimeInterval(cooldownDuration))
    }
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

}
