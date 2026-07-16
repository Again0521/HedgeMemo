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
    private let key = "MemeMemo.ScreenshotSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
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
