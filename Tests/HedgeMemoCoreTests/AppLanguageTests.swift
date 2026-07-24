import XCTest

@testable import HedgeMemoCore

final class AppLanguageTests: XCTestCase {
    func testChineseLocalesChooseSimplifiedChineseInterface() {
        for identifier in ["zh-Hans-CN", "zh-Hant-TW", "zh-HK"] {
            XCTAssertEqual(
                AppLanguage.systemDefault(preferredLanguages: [identifier, "en"]),
                .simplifiedChinese
            )
        }
    }

    func testNonChineseLocalesChooseEnglishInterface() {
        for identifier in ["en-US", "ja-JP", "fr-FR"] {
            XCTAssertEqual(
                AppLanguage.systemDefault(preferredLanguages: [identifier, "zh-Hans"]),
                .english
            )
        }
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: []), .english)
    }

    func testBootstrapPersistsFirstDetectedLanguageAndKeepsExistingChoice() throws {
        let suiteName = "AppLanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AppLanguage.bootstrap(defaults: defaults, preferredLanguages: ["zh-Hans"]),
            .simplifiedChinese
        )
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "zh-Hans")

        XCTAssertEqual(
            AppLanguage.bootstrap(defaults: defaults, preferredLanguages: ["en-US"]),
            .simplifiedChinese
        )
    }

    func testLocalizedResourcesCoverBothLanguages() {
        XCTAssertEqual(L10n.text("设置", language: .simplifiedChinese), "设置")
        XCTAssertEqual(L10n.text("设置", language: .english), "Settings")
        XCTAssertEqual(L10n.format("已选项目格式", 3, language: .english), "3 selected")
    }

    func testSelectingANewLanguagePersistsAndNotifies() throws {
        let suiteName = "AppLanguageSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)

        let notification = expectation(
            forNotification: AppLanguage.didChangeNotification,
            object: nil
        ) { note in
            note.object as? AppLanguage == .english
        }
        AppLanguage.select(.english, defaults: defaults)

        wait(for: [notification], timeout: 0.2)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "en")
    }
}
