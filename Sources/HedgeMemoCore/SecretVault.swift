import CryptoKit
import Foundation
import Security

/// Keychain-backed secret storage for the PIN lock and for encrypting the text
/// of password-category clipboard entries.
///
/// Two separate secrets live here:
///
/// * a **PIN verifier** — a random salt plus a PBKDF2-style iterated hash of the
///   PIN. The PIN itself is never written anywhere, so reading the keychain item
///   does not reveal it.
/// * a **content key** — a random 256-bit AES key used to encrypt password entry
///   text before it reaches persistent clipboard storage.
///
/// The content key is what makes the lock meaningful. Without it a PIN would
/// only hide rows in the UI while the secrets themselves sat in plain text in
/// Application Support, readable by any process running as the user.
public enum SecretVault {
    public enum VaultError: Error {
        case keychainFailure(OSStatus)
        case malformedRecord
        case decryptionFailed
    }

    private static let service = "com.hedgememo.app.vault"

    /// In-memory caches. Every `encrypt`/`decrypt` used to re-read the content
    /// key from the keychain, and `hasPIN` re-queried on each call — on a
    /// locally-signed build each of those reads can raise the system's "allow
    /// access to this key" dialog, which is why the prompt kept reappearing.
    /// Both values are owned exclusively by this type, so caching them cannot
    /// go stale.
    nonisolated(unsafe) private static var cachedContentKey: SymmetricKey?
    nonisolated(unsafe) private static var cachedHasPIN: Bool?
    private static let cacheLock = NSLock()
    private static let pinAccount = "clipboard-pin-verifier"
    private static let contentKeyAccount = "clipboard-content-key"

    // MARK: - PIN

    /// Stored verifier: salt ‖ derived hash. Both fixed-size, so the split on
    /// read is unambiguous.
    private static let saltByteCount = 16
    private static let derivedByteCount = 32
    /// Iterated SHA-256. A clipboard PIN is short, so the work factor is what
    /// makes an offline guess of the keychain item expensive rather than free.
    private static let derivationRounds = 150_000

    public static var hasPIN: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedHasPIN { return cachedHasPIN }
        let exists = (try? loadData(account: pinAccount)) != nil
        cachedHasPIN = exists
        return exists
    }

    public static func setPIN(_ pin: String) throws {
        var salt = Data(count: saltByteCount)
        try salt.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  SecRandomCopyBytes(kSecRandomDefault, saltByteCount, base) == errSecSuccess else {
                throw VaultError.keychainFailure(errSecAllocate)
            }
        }
        let verifier = salt + derive(pin: pin, salt: salt)
        try store(verifier, account: pinAccount)
        cacheLock.lock(); cachedHasPIN = true; cacheLock.unlock()
        // A new PIN must not orphan already-encrypted entries, so the content
        // key is deliberately left in place — it is independent of the PIN.
        _ = try? ensureContentKey()
    }

    public static func verifyPIN(_ pin: String) -> Bool {
        guard let record = try? loadData(account: pinAccount),
              record.count == saltByteCount + derivedByteCount else { return false }
        let salt = record.prefix(saltByteCount)
        let expected = record.suffix(derivedByteCount)
        let candidate = derive(pin: pin, salt: Data(salt))
        // Constant-time compare so a wrong PIN cannot be narrowed down by timing.
        return constantTimeEquals(Data(expected), candidate)
    }

    public static func removePIN() throws {
        try delete(account: pinAccount)
        cacheLock.lock(); cachedHasPIN = false; cacheLock.unlock()
    }

    private static func derive(pin: String, salt: Data) -> Data {
        // Iterated SHA-256 over (salt ‖ pin ‖ previous). CryptoKit ships no
        // PBKDF2, and pulling in CommonCrypto's C API for one call is not worth
        // it; this is the same construction with an explicit work factor.
        var digest = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 1..<derivationRounds {
            digest = Data(SHA256.hash(data: salt + digest))
        }
        return digest
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    // MARK: - Content encryption

    /// AES-GCM sealed box, base64 encoded, behind a version marker so a future
    /// scheme change can be told apart from v1 data instead of being decrypted
    /// with the wrong assumptions.
    private static let cipherPrefix = "hmenc.v1:"

    public static func isEncrypted(_ text: String) -> Bool {
        text.hasPrefix(cipherPrefix)
    }

    public static func encrypt(_ plaintext: String) throws -> String {
        let key = try ensureContentKey()
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw VaultError.malformedRecord }
        return cipherPrefix + combined.base64EncodedString()
    }

    public static func decrypt(_ ciphertext: String) throws -> String {
        guard ciphertext.hasPrefix(cipherPrefix) else { return ciphertext }
        let encoded = String(ciphertext.dropFirst(cipherPrefix.count))
        guard let combined = Data(base64Encoded: encoded) else { throw VaultError.malformedRecord }
        let key = try ensureContentKey()
        let box = try AES.GCM.SealedBox(combined: combined)
        let opened = try AES.GCM.open(box, using: key)
        guard let text = String(data: opened, encoding: .utf8) else { throw VaultError.decryptionFailed }
        return text
    }

    @discardableResult
    public static func ensureContentKey() throws -> SymmetricKey {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedContentKey { return cachedContentKey }
        if let existing = try? loadData(account: contentKeyAccount), existing.count == 32 {
            let key = SymmetricKey(data: existing)
            cachedContentKey = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try store(raw, account: contentKeyAccount)
        cachedContentKey = key
        return key
    }

    // MARK: - Keychain plumbing

    /// `kSecUseDataProtectionKeychain` selects the modern, iOS-style keychain.
    /// Items there belong to the app and are read without the legacy keychain's
    /// per-signature ACL prompt ("HedgeMemo wants to access key …"), which the
    /// file-based keychain raises again every time the app is re-signed.
    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// The data-protection keychain needs an `application-identifier`
    /// entitlement, which a locally-signed build may not carry. Probe it once
    /// and fall back to the legacy keychain rather than failing outright — the
    /// stored data and its protection are the same either way; only the ACL
    /// prompt behaviour differs.
    nonisolated(unsafe) private static var usesDataProtection = true

    private static func isEntitlementFailure(_ status: OSStatus) -> Bool {
        // -34018 errSecMissingEntitlement, plus the generic parameter rejection
        // older systems return for an unsupported query key.
        status == -34018 || status == errSecParam
    }

    private static func store(_ data: Data, account: String) throws {
        do { try store(data, account: account, dataProtection: usesDataProtection) }
        catch VaultError.keychainFailure(let status) where isEntitlementFailure(status) && usesDataProtection {
            usesDataProtection = false
            try store(data, account: account, dataProtection: false)
        }
    }

    private static func store(_ data: Data, account: String, dataProtection: Bool) throws {
        let query = baseQuery(account: account, dataProtection: dataProtection)
        var addition = query
        addition[kSecValueData as String] = data
        // The vault is only meaningful while this Mac is unlocked, and it must
        // never sync to another device.
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addition as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update in place. Deleting the old verifier/key before adding its
            // replacement created a failure window where a transient Keychain
            // error could permanently remove the PIN or orphan encrypted
            // clipboard entries.
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw VaultError.keychainFailure(updateStatus)
            }
        } else if status != errSecSuccess {
            throw VaultError.keychainFailure(status)
        }
    }

    private static func loadData(account: String) throws -> Data {
        guard usesDataProtection else {
            return try loadData(account: account, dataProtection: false)
        }
        do {
            return try loadData(account: account, dataProtection: true)
        } catch VaultError.keychainFailure(let status)
            where isEntitlementFailure(status) || status == errSecItemNotFound {
            // A locally signed build may have created the item in the legacy
            // keychain, then a later release may gain the entitlement required
            // for the data-protection keychain. Probe the legacy location before
            // treating "not found" as a fresh vault; otherwise a new content key
            // would be generated and every existing encrypted entry orphaned.
            do {
                let data = try loadData(account: account, dataProtection: false)
                usesDataProtection = false
                return data
            } catch {
                if isEntitlementFailure(status) { usesDataProtection = false }
                throw error
            }
        }
    }

    private static func loadData(account: String, dataProtection: Bool) throws -> Data {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultError.keychainFailure(status)
        }
        return data
    }

    private static func delete(account: String) throws {
        // Clear both keychains so a fallback never leaves a stale copy behind.
        let legacyStatus = SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw VaultError.keychainFailure(legacyStatus)
        }
        let protectedStatus = SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        guard protectedStatus == errSecSuccess
                || protectedStatus == errSecItemNotFound
                || isEntitlementFailure(protectedStatus) else {
            throw VaultError.keychainFailure(protectedStatus)
        }
    }
}
