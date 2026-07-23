import Foundation

/// UserDefaults keys shared by independent app windows and panels.
/// Keeping the key in one place prevents a settings toggle from silently
/// drifting away from one of its consumers.
enum AppPreferences {
    static let showsScrollIndicatorsKey = "showsScrollIndicators"
    // V2 reverses the first implementation's semantics: zero retains the
    // original glass appearance, while one is a fully opaque background.
    static let interfaceOpacityKey = "interfaceOpacityLevelV2"
    static let defaultInterfaceOpacity = 0.0
    /// Even the zero position keeps a subtle semantic backing over native
    /// glass so text remains readable against a busy desktop.
    static let minimumOpaqueBacking = 0.12

    static func clampedInterfaceOpacity(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func opaqueBackingAlpha(for value: Double) -> Double {
        let level = clampedInterfaceOpacity(value)
        return minimumOpaqueBacking + (1 - minimumOpaqueBacking) * level
    }
}
