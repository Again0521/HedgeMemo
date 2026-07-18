import Combine
import Foundation

@MainActor
public final class ScreenshotSettingsStore: ObservableObject {
    // Mutating `settings` inside its own didSet re-enters the @Published setter;
    // without this guard normalize() recurses until the stack overflows.
    private var isNormalizingSettings = false
    @Published public var settings: ScreenshotSettings {
        didSet {
            guard !isNormalizingSettings else { return }
            isNormalizingSettings = true
            settings.normalize()
            isNormalizingSettings = false
            persist()
        }
    }

    private let defaults: UserDefaults
    private let key = "HedgeMemo.ScreenshotSettings"
    private static let persistentSuite = "com.hedgememo.app"
    // Pre-rename (MemeMemo era) storage; still migrated so an upgraded
    // installation keeps its screenshot preferences.
    private static let legacySuite = "com.memememo.app"
    private static let legacyKey = "MemeMemo.ScreenshotSettings"

    /// Use a fixed suite for shipped builds so moving between debug/release
    /// paths never resets screenshot preferences. An injected defaults store
    /// remains available to tests.
    public init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: Self.persistentSuite) ?? .standard
        self.defaults = resolved
        if defaults == nil, resolved.data(forKey: key) == nil {
            let legacyData = UserDefaults(suiteName: Self.legacySuite)?.data(forKey: Self.legacyKey)
                ?? UserDefaults.standard.data(forKey: Self.legacyKey)
            if let legacyData {
                resolved.set(legacyData, forKey: key)
            }
        }
        if let data = resolved.data(forKey: key),
           var decoded = try? JSONDecoder().decode(ScreenshotSettings.self, from: data) {
            decoded.normalize()
            settings = decoded
        } else {
            settings = ScreenshotSettings()
        }
    }

    public func markCapture(mode: ScreenshotMode) {
        settings = ScreenshotPolicy.settingsAfterCapture(settings, usedMode: mode)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
