import Combine
import Foundation

/// Persists the meme panel's app-wide shortcut independently of the image
/// library, so it remains available before a panel is opened.
@MainActor
public final class MemePanelSettingsStore: ObservableObject {
    @Published public var settings: MemePanelSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key = "HedgeMemo.MemePanelSettings"
    private static let persistentSuite = "com.hedgememo.app"

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.persistentSuite) ?? .standard
        if let data = self.defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(MemePanelSettings.self, from: data) {
            settings = decoded
        } else {
            settings = MemePanelSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
