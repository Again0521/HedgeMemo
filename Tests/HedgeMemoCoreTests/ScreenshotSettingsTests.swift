import XCTest

@testable import HedgeMemoCore

/// Covers `ScreenshotSettings` defaults/migration and `ScreenshotPolicy`.
final class ScreenshotSettingsTests: XCTestCase {
    func testDefaults() {
        let settings = ScreenshotSettings()
        XCTAssertEqual(settings.mode, .smartWindow)
        XCTAssertEqual(settings.hotKey, .defaultScreenshot)
        XCTAssertEqual(settings.hotKeyChoice, .commandShiftP)
        XCTAssertTrue(settings.remembersLastMode)
        XCTAssertTrue(settings.opensEditorAfterCapture)
    }

    func testEditorCanBeDisabled() {
        XCTAssertFalse(ScreenshotSettings(opensEditorAfterCapture: false).opensEditorAfterCapture)
    }

    func testLegacyShortcutMigratesToCommandShiftP() {
        // The initializer runs normalize(), so the legacy pairing is upgraded.
        let migrated = ScreenshotSettings(
            mode: .manualSelection,
            remembersLastMode: true,
            hotKeyChoice: .controlShiftFive,
            hotKey: .legacyScreenshot
        )
        XCTAssertEqual(migrated.hotKey, .defaultScreenshot)
        XCTAssertEqual(migrated.hotKeyChoice, .commandShiftP)
    }

    func testNilHotKeyIsDerivedFromChoice() {
        let commandShiftFive = ScreenshotSettings(hotKeyChoice: .commandShiftFive, hotKey: nil)
        XCTAssertEqual(commandShiftFive.hotKey, HotKeyDefinition(keyCode: 23, key: "5", command: true, shift: true))

        let controlShiftFive = ScreenshotSettings(hotKeyChoice: .controlShiftFive, hotKey: nil)
        XCTAssertEqual(controlShiftFive.hotKey, .legacyScreenshot)
    }

    // MARK: - Policy

    func testResolvedModePrefersExplicitRequest() {
        let settings = ScreenshotSettings(mode: .smartWindow)
        XCTAssertEqual(ScreenshotPolicy.resolvedMode(settings: settings, requestedMode: nil), .smartWindow)
        XCTAssertEqual(ScreenshotPolicy.resolvedMode(settings: settings, requestedMode: .manualSelection), .manualSelection)
    }

    func testSettingsAfterCaptureRemembersOnlyWhenEnabled() {
        let remembering = ScreenshotSettings(mode: .smartWindow, remembersLastMode: true)
        XCTAssertEqual(ScreenshotPolicy.settingsAfterCapture(remembering, usedMode: .manualSelection).mode, .manualSelection)

        let fixed = ScreenshotSettings(mode: .smartWindow, remembersLastMode: false)
        XCTAssertEqual(ScreenshotPolicy.settingsAfterCapture(fixed, usedMode: .manualSelection).mode, .smartWindow)
    }

    func testEnumDisplayNames() {
        XCTAssertFalse(ScreenshotMode.smartWindow.displayName.isEmpty)
        XCTAssertFalse(ScreenshotMode.manualSelection.displayName.isEmpty)
        XCTAssertTrue(ScreenshotHotKeyChoice.controlShiftFive.displayName.contains("Control"))
    }
}
