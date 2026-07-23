import Combine
import Foundation
import HedgeMemoCore

enum AppVersion {
    static let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.5"
}

struct AvailableAppRelease: Equatable, Sendable {
    let version: SemanticVersion
    let title: String
    let pageURL: URL
}

enum UpdateCheckResult: Equatable, Sendable {
    case idle
    case upToDate
    case updateAvailable
    case failed
}

/// Performs a silent GitHub check at most once per local calendar day. Manual
/// checks bypass the daily gate but share the same non-modal, observable state.
@MainActor
final class UpdateCheckStore: ObservableObject {
    @Published private(set) var availableRelease: AvailableAppRelease?
    @Published private(set) var result: UpdateCheckResult = .idle
    @Published private(set) var isChecking = false
    @Published private(set) var showsUpdateBadge = false

    /// GitHub's web latest-release redirect is intentionally used instead of
    /// the anonymous REST endpoint. The latter shares a 60-request/hour quota
    /// by public IP and can fail even when this app has made only one request.
    private static let latestReleaseURL = URL(string: "https://github.com/Again0521/HedgeMemo/releases/latest")!
    private static let lastAutomaticCheckKey = "lastAutomaticUpdateCheckDate.redirect-v2"
    private static let acknowledgedReleaseKey = "acknowledgedUpdateReleaseVersion"
    private static let cachedReleaseVersionKey = "cachedUpdateReleaseVersion"
    private static let cachedReleaseTitleKey = "cachedUpdateReleaseTitle"
    private static let cachedReleaseURLKey = "cachedUpdateReleaseURL"

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let session: URLSession
    private var acknowledgeInFlightResult = false

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, session: URLSession = .shared) {
        self.defaults = defaults
        self.calendar = calendar
        self.session = session
        if let rawVersion = defaults.string(forKey: Self.cachedReleaseVersionKey),
           let version = SemanticVersion(rawVersion),
           let currentVersion = SemanticVersion(AppVersion.display),
           version > currentVersion,
           let title = defaults.string(forKey: Self.cachedReleaseTitleKey),
           let rawURL = defaults.string(forKey: Self.cachedReleaseURLKey),
           let pageURL = URL(string: rawURL) {
            availableRelease = AvailableAppRelease(version: version, title: title, pageURL: pageURL)
            result = .updateAvailable
            let acknowledged = defaults.string(forKey: Self.acknowledgedReleaseKey).flatMap(SemanticVersion.init)
            showsUpdateBadge = UpdateReminderPolicy.shouldShowBadge(release: version, acknowledged: acknowledged)
        }
    }

    func checkAutomaticallyIfNeeded(now: Date = Date()) {
        let lastCheck = defaults.object(forKey: Self.lastAutomaticCheckKey) as? Date
        guard UpdateReminderPolicy.shouldCheckAutomatically(
            lastCheck: lastCheck,
            now: now,
            calendar: calendar
        ) else {
            return
        }
        // Record the attempt before starting the request so repeated lifecycle
        // notifications cannot create a background retry loop while offline.
        defaults.set(now, forKey: Self.lastAutomaticCheckKey)
        checkForUpdates()
    }

    func checkNow() {
        checkForUpdates()
    }

    /// Opening Settings counts as viewing the update. Keep the release link in
    /// place, but stop drawing the menu-bar attention badge for that release.
    func acknowledgeUpdateBadge() {
        showsUpdateBadge = false
        if let version = availableRelease?.version.displayString {
            defaults.set(version, forKey: Self.acknowledgedReleaseKey)
        }
        // If Settings opens while the daily/manual request is still running,
        // its imminent result is already being viewed there. Do not suppress a
        // later, not-yet-started check for a newer release.
        acknowledgeInFlightResult = isChecking
    }

    private func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: Self.latestReleaseURL)
                request.httpMethod = "HEAD"
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("text/html", forHTTPHeaderField: "Accept")
                request.setValue("HedgeMemo/\(AppVersion.display)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 12

                let (_, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let pageURL = httpResponse.url,
                      pageURL.host?.lowercased() == "github.com",
                      pageURL.path.contains("/Again0521/HedgeMemo/releases/tag/") else {
                    throw UpdateCheckError.invalidResponse
                }
                let tagName = pageURL.lastPathComponent.removingPercentEncoding ?? pageURL.lastPathComponent
                guard let releaseVersion = SemanticVersion(tagName),
                      let currentVersion = SemanticVersion(AppVersion.display) else {
                    throw UpdateCheckError.invalidVersion
                }

                if releaseVersion > currentVersion {
                    let releaseTitle = "HedgeMemo-v\(releaseVersion.displayString)"
                    availableRelease = AvailableAppRelease(
                        version: releaseVersion,
                        title: releaseTitle,
                        pageURL: pageURL
                    )
                    defaults.set(releaseVersion.displayString, forKey: Self.cachedReleaseVersionKey)
                    defaults.set(releaseTitle, forKey: Self.cachedReleaseTitleKey)
                    defaults.set(pageURL.absoluteString, forKey: Self.cachedReleaseURLKey)
                    result = .updateAvailable
                    let acknowledgedVersion = defaults.string(forKey: Self.acknowledgedReleaseKey)
                        .flatMap(SemanticVersion.init)
                    if acknowledgeInFlightResult {
                        defaults.set(releaseVersion.displayString, forKey: Self.acknowledgedReleaseKey)
                        showsUpdateBadge = false
                    } else {
                        showsUpdateBadge = UpdateReminderPolicy.shouldShowBadge(
                            release: releaseVersion,
                            acknowledged: acknowledgedVersion
                        )
                    }
                } else {
                    availableRelease = nil
                    showsUpdateBadge = false
                    defaults.removeObject(forKey: Self.cachedReleaseVersionKey)
                    defaults.removeObject(forKey: Self.cachedReleaseTitleKey)
                    defaults.removeObject(forKey: Self.cachedReleaseURLKey)
                    result = .upToDate
                }
            } catch {
                result = .failed
            }
            acknowledgeInFlightResult = false
            isChecking = false
        }
    }
}

private enum UpdateCheckError: Error {
    case invalidResponse
    case invalidVersion
}
