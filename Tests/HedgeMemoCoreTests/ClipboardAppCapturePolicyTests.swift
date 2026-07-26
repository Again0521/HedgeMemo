import Foundation
import XCTest

@testable import HedgeMemoCore

final class ClipboardAppCapturePolicyTests: XCTestCase {
    private let safari = ClipboardSourceApplication(
        bundleIdentifier: "com.apple.Safari",
        displayName: "Safari",
        bundleURLPath: "/Applications/Safari.app"
    )
    private let notes = ClipboardSourceApplication(
        bundleIdentifier: "com.apple.Notes",
        displayName: "Notes",
        bundleURLPath: "/System/Applications/Notes.app"
    )

    func testDisabledModeAllowsKnownAndUnknownSources() {
        XCTAssertTrue(ClipboardAppCapturePolicy.allows(source: safari, mode: .disabled, applications: []))
        XCTAssertTrue(ClipboardAppCapturePolicy.allows(source: nil, mode: .disabled, applications: []))
    }

    func testBlocklistRejectsListedApplicationAndAllowsUnknownSource() {
        XCTAssertFalse(
            ClipboardAppCapturePolicy.allows(source: safari, mode: .blocklist, applications: [safari])
        )
        XCTAssertTrue(
            ClipboardAppCapturePolicy.allows(source: notes, mode: .blocklist, applications: [safari])
        )
        XCTAssertTrue(
            ClipboardAppCapturePolicy.allows(source: nil, mode: .blocklist, applications: [safari])
        )
    }

    func testAllowlistOnlyAcceptsListedApplicationAndRejectsUnknownSource() {
        XCTAssertTrue(
            ClipboardAppCapturePolicy.allows(source: safari, mode: .allowlist, applications: [safari])
        )
        XCTAssertFalse(
            ClipboardAppCapturePolicy.allows(source: notes, mode: .allowlist, applications: [safari])
        )
        XCTAssertFalse(
            ClipboardAppCapturePolicy.allows(source: nil, mode: .allowlist, applications: [safari])
        )
    }

    func testBundleIdentifierMatchingIsCaseInsensitiveAndSurvivesRename() {
        let renamed = ClipboardSourceApplication(
            bundleIdentifier: "COM.APPLE.SAFARI",
            displayName: "Safari Technology Preview",
            bundleURLPath: "/Applications/Other Safari.app"
        )
        XCTAssertTrue(safari.matches(renamed))
        XCTAssertEqual(safari.stableIdentifier, "bundle:com.apple.safari")
    }

    func testSettingsNormalizeDeduplicatesApplicationRules() {
        let duplicate = ClipboardSourceApplication(
            bundleIdentifier: "COM.APPLE.SAFARI",
            displayName: "Safari renamed"
        )
        var settings = ClipboardHistorySettings(
            appFilterMode: .blocklist,
            appFilterApplications: [safari, duplicate, notes]
        )
        settings.normalize()

        XCTAssertEqual(settings.resolvedAppFilterMode, .blocklist)
        XCTAssertEqual(settings.appFilterApplications?.map(\.stableIdentifier), [
            safari.stableIdentifier,
            notes.stableIdentifier,
        ])
    }

    func testLegacySettingsDecodeWithCapturePolicyDisabled() throws {
        let encoded = try JSONEncoder().encode(ClipboardHistorySettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appFilterMode")
        object.removeValue(forKey: "appFilterApplications")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipboardHistorySettings.self, from: legacy)

        XCTAssertEqual(decoded.resolvedAppFilterMode, .disabled)
        XCTAssertEqual(decoded.appFilterApplications ?? [], [])
    }

    func testLegacyEntryDecodesWithoutStableSourceIdentity() throws {
        let entry = ClipboardEntry(
            kind: .text,
            text: "legacy",
            contentHash: "legacy",
            sourceApp: "Old App"
        )
        let encoded = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sourceBundleIdentifier")
        object.removeValue(forKey: "sourceBundleURLPath")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: legacy)

        XCTAssertEqual(decoded.sourceApp, "Old App")
        XCTAssertNil(decoded.sourceBundleIdentifier)
        XCTAssertEqual(decoded.sourceApplication?.stableIdentifier, "name:old app")
    }

    func testInvalidBundleSelectionThrowsInsteadOfBeingIgnored() {
        let invalidURL = URL(fileURLWithPath: "/private/tmp/not-an-application-\(UUID().uuidString)")
        XCTAssertThrowsError(try ClipboardSourceApplication(bundleURL: invalidURL)) { error in
            XCTAssertEqual(
                error as? ClipboardSourceApplicationError,
                .notApplicationBundle(invalidURL)
            )
        }
    }
}
