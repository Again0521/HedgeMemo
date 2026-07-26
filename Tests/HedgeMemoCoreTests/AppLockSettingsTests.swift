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
        XCTAssertTrue(settings.capturesPasswords)
    }

    func testDecodingMinimalPayloadUsesSafeDefaults() throws {
        let settings = try JSONDecoder().decode(
            AppLockSettings.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(settings.timing, .onScreenLock)
        XCTAssertEqual(settings.lockedCategoryKeys, ["password"])
        XCTAssertTrue(settings.allowsBiometrics)
        XCTAssertTrue(settings.capturesPasswords)
    }
}
