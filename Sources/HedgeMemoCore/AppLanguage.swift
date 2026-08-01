import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "appLanguage"
    public static let didChangeNotification = Notification.Name("HedgeMemoAppLanguageDidChange")

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }

    /// Language names stay self-identifying so the picker remains readable
    /// even when the currently selected language is unfamiliar.
    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    public static var current: AppLanguage {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: preferenceKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }
        return preferredSystemLanguage
    }

    /// Persist the initial choice once. Later system-language changes do not
    /// override a choice the user has made in HedgeMemo settings.
    @discardableResult
    public static func bootstrap(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let rawValue = defaults.string(forKey: preferenceKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }
        let language = systemDefault(preferredLanguages: preferredLanguages)
        defaults.set(language.rawValue, forKey: preferenceKey)
        return language
    }

    public static func select(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: preferenceKey) != language.rawValue else { return }
        defaults.set(language.rawValue, forKey: preferenceKey)
        NotificationCenter.default.post(name: didChangeNotification, object: language)
    }

    public static func systemDefault(preferredLanguages: [String]) -> AppLanguage {
        guard let identifier = preferredLanguages.first else { return .english }
        let code = Locale(identifier: identifier).language.languageCode?.identifier
        return code == "zh" ? .simplifiedChinese : .english
    }

    private static var preferredSystemLanguage: AppLanguage {
        systemDefault(preferredLanguages: Locale.preferredLanguages)
    }
}

public enum L10n {
    static let resourceBundleName = "HedgeMemo_HedgeMemoCore.bundle"

    public static func text(_ key: String, language: AppLanguage = .current) -> String {
        guard let bundle = localizationBundle(for: language) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// SwiftPM's resource processing canonicalizes `.lproj` directory names by
    /// lowercasing the region/script subtag — the source `zh-Hans.lproj` ships
    /// as `zh-hans.lproj` in the built bundle. `Bundle.path(forResource:ofType:)`
    /// matches case-sensitively, so a `"zh-Hans"` lookup misses the built folder
    /// and every zh-Hans key falls back to itself (Chinese labels still look
    /// right because they are self-keyed, but format keys like "使用次数格式"
    /// leak). Try the declared name first, then the lowercased form, so the
    /// lookup succeeds against both the source and the processed bundle.
    private static func localizationBundle(for language: AppLanguage) -> Bundle? {
        let resources = packagedResourceBundle(resourcesURL: Bundle.main.resourceURL) ?? Bundle.module
        var seen = Set<String>()
        for name in [language.rawValue, language.rawValue.lowercased()] where seen.insert(name).inserted {
            if let path = resources.path(forResource: name, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    /// SwiftPM's generated `Bundle.module` accessor only checks beside the
    /// main bundle, while a normal macOS app stores resource bundles under
    /// `Contents/Resources`. Prefer that standard installed-app location so a
    /// packaged build does not fall through to SwiftPM's temporary build path.
    static func packagedResourceBundle(resourcesURL: URL?) -> Bundle? {
        guard let resourcesURL else { return nil }
        return Bundle(url: resourcesURL.appendingPathComponent(resourceBundleName, isDirectory: true))
    }

    public static func format(
        _ key: String,
        _ arguments: CVarArg...,
        language: AppLanguage = .current
    ) -> String {
        let format = text(key, language: language)
        return String(format: format, locale: language.locale, arguments: arguments)
    }
}
