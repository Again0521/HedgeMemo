import XCTest

@testable import HedgeMemoCore

@MainActor
final class ClipboardAdvancedModeTests: XCTestCase {
    private let safari = ClipboardSourceApplication(
        bundleIdentifier: "com.apple.Safari",
        displayName: "Safari"
    )
    private let notes = ClipboardSourceApplication(
        bundleIdentifier: "com.apple.Notes",
        displayName: "Notes"
    )

    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-advanced-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry(
        _ text: String,
        captured: TimeInterval,
        lastUsed: TimeInterval? = nil,
        useCount: Int? = nil,
        source: ClipboardSourceApplication? = nil,
        pinned: Bool = false,
        pinnedOrder: Int? = nil,
        desktopOrder: Int? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(
            kind: .text,
            text: text,
            contentHash: text,
            createdAt: Date(timeIntervalSinceReferenceDate: captured),
            lastUsedAt: lastUsed.map(Date.init(timeIntervalSinceReferenceDate:)),
            useCount: useCount,
            sourceApp: source?.displayName,
            sourceBundleIdentifier: source?.bundleIdentifier,
            sourceBundleURLPath: source?.bundleURLPath,
            isPinned: pinned,
            pinnedOrder: pinnedOrder,
            isDesktopPinned: desktopOrder != nil,
            desktopPinnedOrder: desktopOrder
        )
    }

    func testSourceFilterUsesStableIdentityAndSupportsUnknownSource() {
        let safariEntry = entry("Safari", captured: 1, source: safari)
        let notesEntry = entry("Notes", captured: 2, source: notes)
        let unknownEntry = entry("Unknown", captured: 3)

        let safariOnly = ClipboardHistoryPolicy.ordered(
            [safariEntry, notesEntry, unknownEntry],
            advancedOptions: ClipboardAdvancedOptions(
                sourceIdentifier: safari.stableIdentifier
            )
        )
        XCTAssertEqual(safariOnly.map(\.id), [safariEntry.id])

        let unknownOnly = ClipboardHistoryPolicy.ordered(
            [safariEntry, notesEntry, unknownEntry],
            advancedOptions: ClipboardAdvancedOptions(
                sourceIdentifier: ClipboardAdvancedOptions.unknownSourceIdentifier
            )
        )
        XCTAssertEqual(unknownOnly.map(\.id), [unknownEntry.id])
    }

    func testCapturedTimeSortsInBothDirections() {
        let oldest = entry("old", captured: 1)
        let newest = entry("new", captured: 3)
        let middle = entry("middle", captured: 2)
        let values = [oldest, newest, middle]

        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(
                values,
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .capturedAt,
                    sortDirection: .descending
                )
            ).map(\.id),
            [newest.id, middle.id, oldest.id]
        )
        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(
                values,
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .capturedAt,
                    sortDirection: .ascending
                )
            ).map(\.id),
            [oldest.id, middle.id, newest.id]
        )
    }

    func testLastUsedSortKeepsNeverUsedEntriesAtEnd() {
        let never = entry("never", captured: 30)
        let earlier = entry("earlier", captured: 20, lastUsed: 5)
        let later = entry("later", captured: 10, lastUsed: 9)
        let values = [never, earlier, later]

        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(
                values,
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .lastUsedAt,
                    sortDirection: .descending
                )
            ).map(\.id),
            [later.id, earlier.id, never.id]
        )
        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(
                values,
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .lastUsedAt,
                    sortDirection: .ascending
                )
            ).map(\.id),
            [earlier.id, later.id, never.id]
        )
    }

    func testUseCountTreatsMissingAsZeroAndSortsInBothDirections() {
        let unused = entry("unused", captured: 3)
        let once = entry("once", captured: 2, useCount: 1)
        let frequent = entry("frequent", captured: 1, useCount: 20)
        let values = [once, unused, frequent]

        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(
                values,
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .useCount,
                    sortDirection: .descending
                )
            ).map(\.id),
            [frequent.id, once.id, unused.id]
        )
        XCTAssertEqual(
            ClipboardHistoryPolicy.ordered(
                values,
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .useCount,
                    sortDirection: .ascending
                )
            ).map(\.id),
            [unused.id, once.id, frequent.id]
        )
    }

    func testAdvancedSortPreservesClipboardAndDesktopPinContracts() {
        let pinned = entry(
            "clipboard pin",
            captured: 0,
            useCount: 0,
            pinned: true,
            pinnedOrder: 0
        )
        let ordinary = (0..<12).map {
            entry("ordinary-\($0)", captured: TimeInterval($0), useCount: $0)
        }
        let firstDesktop = entry(
            "desktop first",
            captured: 100,
            useCount: 100,
            desktopOrder: 0
        )
        let secondDesktop = entry(
            "desktop second",
            captured: 101,
            useCount: 200,
            desktopOrder: 1
        )

        let ordered = ClipboardHistoryPolicy.ordered(
            ordinary + [secondDesktop, pinned, firstDesktop],
            advancedOptions: ClipboardAdvancedOptions(
                sortField: .useCount,
                sortDirection: .ascending
            )
        )
        XCTAssertEqual(ordered.first?.id, pinned.id)
        XCTAssertEqual(ordered[9].id, firstDesktop.id)
        XCTAssertEqual(ordered[10].id, secondDesktop.id)
    }

    func testAdvancedOptionsComposeWithCategoryAndSearchFiltering() {
        let safariWork = entry("WORK-123", captured: 1, source: safari)
        let safariOther = entry("HOME-123", captured: 2, source: safari)
        let notesWork = entry("WORK-456", captured: 3, source: notes)
        let category = CustomClipboardCategory(name: "Work", pattern: "^WORK-")

        let filtered = ClipboardHistoryPolicy.ordered(
            [safariWork, safariOther, notesWork],
            query: "123",
            key: .custom(category.id),
            customCategories: [category],
            advancedOptions: ClipboardAdvancedOptions(
                sourceIdentifier: safari.stableIdentifier
            )
        )
        XCTAssertEqual(filtered.map(\.id), [safariWork.id])
    }

    func testSettingsPersistAndLegacyValuesUseSafeDefaults() throws {
        var settings = ClipboardHistorySettings()
        settings.advancedModeEnabled = true
        settings.advancedSourceIdentifier = safari.stableIdentifier
        settings.advancedSortField = .useCount
        settings.advancedSortDirection = .ascending

        let roundTrip = try JSONDecoder().decode(
            ClipboardHistorySettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(roundTrip.resolvedAdvancedModeEnabled)
        XCTAssertEqual(roundTrip.advancedSourceIdentifier, safari.stableIdentifier)
        XCTAssertEqual(roundTrip.resolvedAdvancedSortField, .useCount)
        XCTAssertEqual(roundTrip.resolvedAdvancedSortDirection, .ascending)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ClipboardHistorySettings()))
                as? [String: Any]
        )
        object.removeValue(forKey: "advancedModeEnabled")
        object.removeValue(forKey: "advancedSourceIdentifier")
        object.removeValue(forKey: "advancedSortField")
        object.removeValue(forKey: "advancedSortDirection")
        let legacy = try JSONDecoder().decode(
            ClipboardHistorySettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(legacy.resolvedAdvancedModeEnabled)
        XCTAssertNil(legacy.advancedSourceIdentifier)
        XCTAssertEqual(legacy.resolvedAdvancedSortField, .capturedAt)
        XCTAssertEqual(legacy.resolvedAdvancedSortDirection, .descending)
    }

    func testAdvancedChromeAddsExactlyOneFilterRow() {
        XCTAssertEqual(
            ClipboardPanelLayout.chromeHeight(advancedMode: true)
                - ClipboardPanelLayout.chromeHeight(advancedMode: false),
            ClipboardPanelLayout.sectionSpacing + ClipboardPanelLayout.advancedFilterHeight
        )
        XCTAssertEqual(
            ClipboardPanelLayout.panelHeight(
                contentHeight: 0,
                availableHeight: 1_000,
                advancedMode: true
            ),
            ClipboardPanelLayout.chromeHeight(advancedMode: true)
                + ClipboardPanelLayout.emptyStateHeight
        )
    }

    func testSourceMenuCacheInvalidatesWithEntriesAndExcludesSecrets() {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(rootURL: tempRoot("sources"))
        )
        XCTAssertTrue(store.addText("Safari text", source: safari))
        XCTAssertEqual(store.sourceApplicationsForFiltering().map(\.stableIdentifier), [
            safari.stableIdentifier
        ])

        XCTAssertTrue(store.addText("Notes text", source: notes))
        XCTAssertEqual(
            Set(store.sourceApplicationsForFiltering().map(\.stableIdentifier)),
            [safari.stableIdentifier, notes.stableIdentifier]
        )

        let passwordManager = ClipboardSourceApplication(
            bundleIdentifier: "com.example.passwords",
            displayName: "Passwords"
        )
        XCTAssertTrue(store.addPassword("secret", source: passwordManager))
        XCTAssertFalse(
            store.sourceApplicationsForFiltering()
                .contains { $0.stableIdentifier == passwordManager.stableIdentifier }
        )
        XCTAssertTrue(
            store.sourceApplicationsForFiltering(includeSecrets: true)
                .contains { $0.stableIdentifier == passwordManager.stableIdentifier }
        )
    }

    func testStoreMemoSeparatesStandardAndAdvancedOrdering() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("memo"))
        let olderFrequent = entry("frequent", captured: 1, useCount: 50)
        let newerUnused = entry("unused", captured: 2, useCount: 0)
        try repository.save(
            ClipboardHistorySnapshot(entries: [olderFrequent, newerUnused])
        )
        let store = ClipboardHistoryStore(repository: repository)

        XCTAssertEqual(store.orderedEntries().map(\.id), [
            newerUnused.id, olderFrequent.id
        ])
        XCTAssertEqual(
            store.orderedEntries(
                advancedOptions: ClipboardAdvancedOptions(
                    sortField: .useCount,
                    sortDirection: .descending
                )
            ).map(\.id),
            [olderFrequent.id, newerUnused.id]
        )
        XCTAssertEqual(store.orderedEntries().map(\.id), [
            newerUnused.id, olderFrequent.id
        ])
    }
}
