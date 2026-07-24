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
    public static func text(_ key: String, language: AppLanguage = .current) -> String {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
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
