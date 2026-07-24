import XCTest

@testable import HedgeMemoCore

/// Covers `HotKeyDefinition` validity/labels and `HotKeyPolicy` conflict rules.
final class HotKeyTests: XCTestCase {
    func testUsabilityRequiresAKeyAndAModifier() {
        XCTAssertTrue(HotKeyDefinition(keyCode: 9, key: "V", command: true).isUsable)
        XCTAssertFalse(HotKeyDefinition(keyCode: 9, key: "V").isUsable, "no modifier is unusable")
        XCTAssertFalse(HotKeyDefinition(keyCode: 0, key: "V", command: true).isUsable, "no key code is unusable")
        XCTAssertFalse(HotKeyDefinition(keyCode: 9, key: "", command: true).isUsable, "empty key is unusable")
    }

    func testDisplayNameListsModifiersInOrderThenKey() {
        let hotKey = HotKeyDefinition(keyCode: 9, key: "V", command: true, option: true, control: true, shift: true)
        XCTAssertEqual(hotKey.displayName, "Command + Option + Control + Shift + V")
        XCTAssertEqual(HotKeyDefinition(keyCode: 9, key: "V", command: true, option: true).displayName, "Command + Option + V")
    }

    func testBuiltInDefaults() {
        XCTAssertEqual(HotKeyDefinition.defaultClipboard.displayName, "Command + Shift + V")
        XCTAssertEqual(HotKeyDefinition.defaultScreenshot.displayName, "Command + Shift + P")
        XCTAssertEqual(HotKeyDefinition.defaultMemePanel.displayName, "Command + Shift + E")
    }

    func testConflictsOnlyBetweenIdenticalUsableHotKeys() {
        let hotKey = HotKeyDefinition(keyCode: 9, key: "V", command: true, option: true)
        XCTAssertTrue(HotKeyPolicy.conflicts(hotKey, hotKey))
        XCTAssertFalse(HotKeyPolicy.conflicts(hotKey, .defaultScreenshot))
        let unusable = HotKeyDefinition(keyCode: 9, key: "V")
        XCTAssertFalse(HotKeyPolicy.conflicts(unusable, unusable), "unusable hotkeys never conflict")
    }

    func testLabelForMissingOrUnusableHotKey() {
        XCTAssertEqual(HotKeyPolicy.label(nil), L10n.text("未设置"))
        XCTAssertEqual(HotKeyPolicy.label(HotKeyDefinition(keyCode: 9, key: "V")), L10n.text("未设置"))
        XCTAssertEqual(HotKeyPolicy.label(.defaultClipboard), "Command + Shift + V")
    }
}
