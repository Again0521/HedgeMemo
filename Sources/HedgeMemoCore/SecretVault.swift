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
///   text before it reaches `clipboard-history.json`.
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
        (try? loadData(account: pinAccount)) != nil
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
        if let existing = try? loadData(account: contentKeyAccount), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try store(raw, account: contentKeyAccount)
        return key
    }

    // MARK: - Keychain plumbing

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func store(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        // The vault is only meaningful while this Mac is unlocked, and it must
        // never sync to another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainFailure(status) }
    }

    private static func loadData(account: String) throws -> Data {
        var query = baseQuery(account: account)
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
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainFailure(status)
        }
    }
}
