import XCTest
@testable import HedgeMemoCore

final class AppLockSettingsTests: XCTestCase {
    func testDecodingOlderPayloadPreservesExistingChoicesAndDefaultsNewFields() throws {
        let payload = """
        {
          "timing": "idle15",
          "lockedCategoryKeys": ["code"],
          "allowsBiometrics": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppLockSettings.self, from: payload)

        XCTAssertEqual(settings.timing, .idle15)
        XCTAssertEqual(settings.lockedCategoryKeys, ["code"])
        XCTAssertFalse(settings.allowsBiometrics)
        XCTAssertFalse(settings.capturesPasswords)
    }

    func testDecodingMinimalPayloadUsesSafeDefaults() throws {
        let settings = try JSONDecoder().decode(
            AppLockSettings.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(settings.timing, .onScreenLock)
        XCTAssertEqual(settings.lockedCategoryKeys, ["password"])
        XCTAssertTrue(settings.allowsBiometrics)
        XCTAssertFalse(settings.capturesPasswords)
    }

    @MainActor
    func testStoreDoesNotReadPINStateUntilVaultAccessIsRequested() {
        let defaults = isolatedDefaults()
        var loadCount = 0
        let store = AppLockStore(defaults: defaults) {
            loadCount += 1
            return true
        }

        XCTAssertEqual(loadCount, 0, "initializing the application must not query Keychain")
        XCTAssertFalse(store.hasPIN, "unloaded state must not pretend a PIN was inspected")

        store.prepareVaultAccess()
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(store.hasPIN)

        store.prepareVaultAccess()
        XCTAssertEqual(loadCount, 1, "PIN state is cached for the process lifetime")
    }

    @MainActor
    func testPrivacyMigrationDisablesPasswordCaptureOnceThenPreservesExplicitOptIn() throws {
        let defaults = isolatedDefaults()
        let settingsKey = "HedgeMemo.AppLockSettings"
        defaults.set(
            try JSONEncoder().encode(AppLockSettings(capturesPasswords: true)),
            forKey: settingsKey
        )

        let migrated = AppLockStore(defaults: defaults, pinStateLoader: { false })
        XCTAssertFalse(migrated.settings.capturesPasswords)

        migrated.settings.capturesPasswords = true
        let reloaded = AppLockStore(defaults: defaults, pinStateLoader: { false })
        XCTAssertTrue(
            reloaded.settings.capturesPasswords,
            "an opt-in made after migration must persist"
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "HedgeMemoTests.AppLock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
