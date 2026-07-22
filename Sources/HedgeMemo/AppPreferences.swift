import Foundation

/// UserDefaults keys shared by independent app windows and panels.
/// Keeping the key in one place prevents a settings toggle from silently
/// drifting away from one of its consumers.
enum AppPreferences {
    static let showsScrollIndicatorsKey = "showsScrollIndicators"
}
