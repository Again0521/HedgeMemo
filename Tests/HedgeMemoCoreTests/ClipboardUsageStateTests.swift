import Foundation
import XCTest
@testable import HedgeMemoCore

final class ClipboardUsageStateTests: XCTestCase {
    func testCompactUsageStateReducesEveryClipboardEntryStride() {
        XCTAssertEqual(ClipboardEntry.usageStateStorageStride, 24)
        XCTAssertEqual(ClipboardEntry.storageStride, 168)
        XCTAssertEqual(ClipboardEntry.legacyUsageStorageStrideForTesting, 176)
        XCTAssertGreaterThanOrEqual(
            ClipboardEntry.legacyUsageStorageStrideForTesting
                - ClipboardEntry.storageStride,
            8
        )
        XCTAssertGreaterThanOrEqual(
            10_000 * (
                ClipboardEntry.legacyUsageStorageStrideForTesting
                    - ClipboardEntry.storageStride
            ),
            80_000
        )
    }

    func testAllFourUsageCombinationsKeepExactCodableFields() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123_456.75)
        let fixtures: [(Date?, Int?)] = [
            (nil, nil),
            (date, nil),
            (nil, 17),
            (date, 17),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for (lastUsedAt, useCount) in fixtures {
            let entry = ClipboardEntry(
                kind: .text,
                text: "usage",
                contentHash: UUID().uuidString,
                lastUsedAt: lastUsedAt,
                useCount: useCount
            )
            let data = try encoder.encode(entry)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(
                object["lastUsedAt"] != nil,
                lastUsedAt != nil
            )
            XCTAssertEqual(object["useCount"] as? Int, useCount)

            let decoded = try decoder.decode(ClipboardEntry.self, from: data)
            XCTAssertEqual(decoded.lastUsedAt, lastUsedAt)
            XCTAssertEqual(decoded.useCount, useCount)
            XCTAssertEqual(decoded, entry)
            XCTAssertEqual(decoded.hashValue, entry.hashValue)
        }
    }

    func testIndependentUsageMutationsPreserveClipboardEntryValueSemantics() {
        let original = ClipboardEntry(
            kind: .text,
            text: "original",
            contentHash: "usage-copy"
        )
        var edited = original
        let firstDate = Date(timeIntervalSinceReferenceDate: 42)

        edited.lastUsedAt = firstDate
        XCTAssertEqual(edited.lastUsedAt, firstDate)
        XCTAssertNil(edited.useCount)

        edited.useCount = 9
        XCTAssertEqual(edited.lastUsedAt, firstDate)
        XCTAssertEqual(edited.useCount, 9)

        edited.lastUsedAt = nil
        XCTAssertNil(edited.lastUsedAt)
        XCTAssertEqual(edited.useCount, 9)

        edited.useCount = nil
        XCTAssertNil(edited.lastUsedAt)
        XCTAssertNil(edited.useCount)
        XCTAssertNil(original.lastUsedAt)
        XCTAssertNil(original.useCount)
        XCTAssertEqual(original.text, "original")
    }

    func testFullIntDomainAndWideDatesRemainLosslessInMemory() {
        let dates = [
            Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude),
            Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude),
        ]
        let counts = [Int.min, Int.max]

        for (date, count) in zip(dates, counts) {
            var entry = ClipboardEntry(
                kind: .text,
                text: "extreme",
                contentHash: UUID().uuidString,
                lastUsedAt: date,
                useCount: count
            )
            XCTAssertEqual(entry.lastUsedAt, date)
            XCTAssertEqual(entry.useCount, count)

            entry.lastUsedAt = nil
            XCTAssertNil(entry.lastUsedAt)
            XCTAssertEqual(entry.useCount, count)
            entry.lastUsedAt = date
            entry.useCount = nil
            XCTAssertEqual(entry.lastUsedAt, date)
            XCTAssertNil(entry.useCount)
        }
    }

    func testTenThousandUnusedEntriesKeepExactDefaultSemantics() {
        let entries = (0..<10_000).map { index in
            ClipboardEntry(
                kind: .text,
                text: "body-\(index)",
                contentHash: "unused-\(index)"
            )
        }

        XCTAssertTrue(entries.allSatisfy {
            $0.lastUsedAt == nil && $0.useCount == nil
        })
    }

    func testUsageChangesDoNotTouchPinSourceOrTextStates() {
        var entry = ClipboardEntry(
            kind: .text,
            text: "body",
            contentHash: "usage-independent",
            sourceApp: "Notes",
            sourceBundleIdentifier: "com.apple.Notes",
            isPinned: true,
            pinnedOrder: 2
        )
        let sourceBox = entry.sourceMetadataBoxForInterning

        entry.lastUsedAt = Date(timeIntervalSinceReferenceDate: 100)
        entry.useCount = 4

        XCTAssertEqual(entry.text, "body")
        XCTAssertEqual(entry.sourceApp, "Notes")
        XCTAssertTrue(entry.sourceMetadataBoxForInterning === sourceBox)
        XCTAssertTrue(entry.isPinned)
        XCTAssertEqual(entry.pinnedOrder, 2)
        XCTAssertEqual(entry.isDesktopPinned, false)
    }
}
