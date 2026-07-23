import Foundation
import XCTest

@testable import HedgeMemoCore

final class MemePanelSettingsTests: XCTestCase {
    func testDefaultsToCommandShiftE() {
        XCTAssertEqual(MemePanelSettings().hotKey, .defaultMemePanel)
    }

    @MainActor
    func testPersistsCustomHotKey() {
        let suite = "HedgeMemo.MemePanelSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let custom = HotKeyDefinition(keyCode: 8, key: "C", command: true, option: true)
        let store = MemePanelSettingsStore(defaults: defaults)
        store.settings.hotKey = custom

        XCTAssertEqual(MemePanelSettingsStore(defaults: defaults).settings.hotKey, custom)
    }
}
