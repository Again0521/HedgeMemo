import Combine
import Foundation

@MainActor
public final class AppLockStore: ObservableObject {
    private var isNormalizingSettings = false
    @Published public var settings: AppLockSettings {
        didSet {
            guard !isNormalizingSettings else { return }
            isNormalizingSettings = true
            settings.normalize()
            isNormalizingSettings = false
            persist()
        }
    }

    /// When the current session was unlocked; nil means locked. Published so the
    /// panel can swap between the list and the unlock screen.
    @Published public private(set) var unlockedAt: Date?
    /// Last interaction with unlocked content, used by the idle timing.
    private var lastUsedAt: Date?
    @Published public private(set) var failedAttempts = 0
    /// When PIN entry becomes available again. Persisted, because a cooldown
    /// that only lived in memory would be shrugged off by quitting and
    /// relaunching the app.
    @Published public private(set) var cooldownUntil: Date?

    private let defaults: UserDefaults
    private let key = "HedgeMemo.AppLockSettings"
    private static let persistentSuite = "com.hedgememo.app"

    public init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: Self.persistentSuite) ?? .standard
        self.defaults = resolved
        if let data = resolved.data(forKey: key),
           var decoded = try? JSONDecoder().decode(AppLockSettings.self, from: data) {
            decoded.normalize()
            settings = decoded
        } else {
            settings = AppLockSettings()
        }
        failedAttempts = resolved.integer(forKey: Self.failedAttemptsKey)
        cooldownUntil = resolved.object(forKey: Self.cooldownUntilKey) as? Date
        // Password capture became on-by-default after some builds had already
        // persisted it as off. A stored value would otherwise win forever and
        // the new default would never reach those installs, so apply it once.
        if !resolved.bool(forKey: Self.capturedDefaultAppliedKey) {
            resolved.set(true, forKey: Self.capturedDefaultAppliedKey)
            settings.capturesPasswords = true
        }
    }

    private static let capturedDefaultAppliedKey = "HedgeMemo.AppLock.appliedPasswordCaptureDefault"
    private static let failedAttemptsKey = "HedgeMemo.AppLock.failedAttempts"
    private static let cooldownUntilKey = "HedgeMemo.AppLock.cooldownUntil"

    /// Cached because `gateState` is read from SwiftUI bodies on every render,
    /// and `SecretVault.hasPIN` is a synchronous Keychain query. Hitting the
    /// keychain once per body pass stalled the render loop — the flicker and
    /// judder when switching to the 密码 category. Only this type mutates the
    /// PIN, so the cache cannot go stale behind our back.
    @Published public private(set) var hasPIN: Bool = SecretVault.hasPIN

    /// What a protected surface should show right now.
    public enum GateState: Equatable, Sendable {
        /// Not protected, or already unlocked for this session.
        case open
        /// Protected but no PIN exists yet — first entry is where one is created.
        case needsSetup
        case needsUnlock
    }

    /// Whether the current unlock session is still valid.
    private var isSessionUnlocked: Bool {
        AppLockPolicy.remainsUnlocked(
            settings: settings,
            unlockedAt: unlockedAt,
            lastUsedAt: lastUsedAt,
            now: .now
        )
    }

    /// True when locked content should be withheld right now.
    public var isLocked: Bool { !isSessionUnlocked }

    /// The 密码 category always requires the gate — it holds nothing but
    /// secrets, so protecting it is not something the user has to remember to
    /// switch on. Every other surface is protected only when configured.
    public func gateState(forCategory key: ClipboardCategoryKey) -> GateState {
        gate(isProtected: key == .builtin(.password) || settings.isCategoryLocked(key))
    }

    public var memePanelGateState: GateState {
        gate(isProtected: settings.locksMemePanel)
    }

    private func gate(isProtected: Bool) -> GateState {
        guard isProtected else { return .open }
        if isSessionUnlocked { return .open }
        return hasPIN ? .needsUnlock : .needsSetup
    }

    public func isCategoryLocked(_ key: ClipboardCategoryKey) -> Bool {
        gateState(forCategory: key) != .open
    }

    // MARK: - PIN lifecycle

    /// Sets or replaces the PIN.
    public func setPIN(_ pin: String) throws {
        try SecretVault.setPIN(pin)
        hasPIN = true
        failedAttempts = 0
        cooldownUntil = nil
        persistAttemptState()
    }

    /// Removes the PIN. Protected surfaces fall back to the first-run setup
    /// gate, so nothing becomes silently readable.
    public func removePIN() throws {
        try SecretVault.removePIN()
        hasPIN = false
        unlockedAt = nil
        failedAttempts = 0
        cooldownUntil = nil
        persistAttemptState()
    }

    /// Seconds until PIN entry is allowed again; zero when it already is.
    public var cooldownRemaining: TimeInterval {
        AppLockPolicy.cooldownRemaining(until: cooldownUntil, now: .now)
    }

    public var isCoolingDown: Bool { cooldownRemaining > 0 }

    @discardableResult
    public func unlock(pin: String) -> Bool {
        // Refuse before verifying: checking first would let an attacker keep
        // testing candidates throughout the penalty and make it decorative.
        guard !isCoolingDown else { return false }
        guard SecretVault.verifyPIN(pin) else {
            let outcome = AppLockPolicy.afterFailedAttempt(failedAttempts: failedAttempts, now: .now)
            failedAttempts = outcome.failedAttempts
            cooldownUntil = outcome.cooldownUntil
            persistAttemptState()
            return false
        }
        markUnlocked()
        return true
    }

    /// Used by the biometric path, which has already been verified by
    /// LocalAuthentication against the user's own Touch ID / password.
    /// Also clears any cooldown: reaching here means the user proved themselves,
    /// either with the right PIN or with Touch ID.
    public func markUnlocked() {
        failedAttempts = 0
        cooldownUntil = nil
        persistAttemptState()
        unlockedAt = .now
        lastUsedAt = .now
    }

    public func noteActivity() {
        guard unlockedAt != nil else { return }
        lastUsedAt = .now
    }

    public func lock() {
        unlockedAt = nil
        lastUsedAt = nil
    }

    /// Locking the Mac re-locks in every mode; the timing option only decides
    /// whether there is also an idle timeout.
    public func handleScreenLocked() {
        lock()
    }

    private func persistAttemptState() {
        defaults.set(failedAttempts, forKey: Self.failedAttemptsKey)
        if let cooldownUntil {
            defaults.set(cooldownUntil, forKey: Self.cooldownUntilKey)
        } else {
            defaults.removeObject(forKey: Self.cooldownUntilKey)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
