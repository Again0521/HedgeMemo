import XCTest
@testable import HedgeMemoCore

final class PasswordDisplayTests: XCTestCase {
    func testUnlockedProjectionRevealsPlaintextWithoutChangingStoredEntry() {
        let stored = ClipboardEntry(
            kind: .text,
            text: "hmenc.v1:ciphertext",
            contentHash: "secret",
            origin: .concealedPassword
        )

        let display = stored.displayProjection(revealedSecret: "correct horse battery staple")

        XCTAssertEqual(display.text, "correct horse battery staple")
        XCTAssertEqual(stored.text, "hmenc.v1:ciphertext")
        XCTAssertTrue(display.isSecret)
    }

    func testFailedDecryptionProjectionNeverDisplaysCiphertext() {
        let stored = ClipboardEntry(
            kind: .text,
            text: "hmenc.v1:ciphertext",
            contentHash: "secret",
            origin: .concealedPassword
        )

        let display = stored.displayProjection(revealedSecret: nil)

        XCTAssertNil(display.text)
        XCTAssertEqual(display.previewText, L10n.text("已隐藏的密码"))
    }
}
