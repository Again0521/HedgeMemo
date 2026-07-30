import Foundation
import XCTest
@testable import HedgeMemoCore

final class ClipboardPinStateTests: XCTestCase {
    func testCompactPinStateReducesEveryClipboardEntryStride() {
        XCTAssertEqual(ClipboardEntry.pinStateStorageStride, 8)
        XCTAssertLessThanOrEqual(ClipboardEntry.storageStride, 176)
        XCTAssertEqual(ClipboardEntry.legacyPinStorageStrideForTesting, 208)
        XCTAssertGreaterThanOrEqual(
            ClipboardEntry.legacyPinStorageStrideForTesting
                - ClipboardEntry.storageStride,
            32
        )

        XCTAssertGreaterThanOrEqual(
            10_000 * (
                ClipboardEntry.legacyPinStorageStrideForTesting
                    - ClipboardEntry.storageStride
            ),
            320_000
        )
    }

    func testTenThousandOrdinaryEntriesAllocateNoPinBoxes() {
        let entries = (0..<10_000).map { index in
            ClipboardEntry(
                kind: .text,
                text: "body-\(index)",
                contentHash: "ordinary-pin-\(index)"
            )
        }

        XCTAssertTrue(entries.allSatisfy {
            !$0.hasAllocatedPinStateForTesting
                && !$0.isPinned
                && $0.pinnedOrder == nil
                && $0.isDesktopPinned == false
                && $0.desktopPinnedOrder == nil
        })
    }

    func testLegacyMissingDesktopFlagAlsoAllocatesNoPinBox() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(
                    ClipboardEntry(
                        kind: .text,
                        text: "legacy",
                        contentHash: "legacy-pin"
                    )
                )
            ) as? [String: Any]
        )
        object.removeValue(forKey: "isDesktopPinned")

        let decoded = try JSONDecoder().decode(
            ClipboardEntry.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.hasAllocatedPinStateForTesting)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertNil(decoded.pinnedOrder)
        XCTAssertNil(decoded.isDesktopPinned)
        XCTAssertNil(decoded.desktopPinnedOrder)

        let roundTrip = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(decoded)
            ) as? [String: Any]
        )
        XCTAssertEqual(roundTrip["isPinned"] as? Bool, false)
        XCTAssertNil(roundTrip["isDesktopPinned"])
    }

    func testPinnedCopiesRetainValueSemanticsAndReturnToOrdinaryState() {
        let original = ClipboardEntry(
            kind: .text,
            text: "pin me",
            contentHash: "pin-copy"
        )
        var quickPinned = original
        quickPinned.isPinned = true
        quickPinned.pinnedOrder = 4
        var bothPinned = quickPinned
        bothPinned.isDesktopPinned = true
        bothPinned.desktopPinnedOrder = 2

        XCTAssertFalse(original.hasAllocatedPinStateForTesting)
        XCTAssertFalse(original.isPinned)
        XCTAssertTrue(quickPinned.hasAllocatedPinStateForTesting)
        XCTAssertTrue(quickPinned.isPinned)
        XCTAssertEqual(quickPinned.pinnedOrder, 4)
        XCTAssertEqual(quickPinned.isDesktopPinned, false)
        XCTAssertTrue(bothPinned.isPinned)
        XCTAssertEqual(bothPinned.pinnedOrder, 4)
        XCTAssertEqual(bothPinned.isDesktopPinned, true)
        XCTAssertEqual(bothPinned.desktopPinnedOrder, 2)

        bothPinned.isPinned = false
        bothPinned.pinnedOrder = nil
        bothPinned.isDesktopPinned = false
        bothPinned.desktopPinnedOrder = nil
        XCTAssertFalse(bothPinned.hasAllocatedPinStateForTesting)
        XCTAssertFalse(bothPinned.isPinned)
        XCTAssertEqual(bothPinned.isDesktopPinned, false)
    }

    func testAllPinFieldCombinationsKeepExactCodableRepresentation() throws {
        let fixtures: [(Bool, Int?, Bool?, Int?)] = [
            (false, nil, false, nil),
            (false, nil, nil, nil),
            (true, nil, false, nil),
            (true, 7, false, nil),
            (false, nil, true, nil),
            (false, nil, true, 3),
            (true, 5, true, 9),
            (false, 11, false, 13),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for (isPinned, pinnedOrder, isDesktopPinned, desktopOrder) in fixtures {
            let entry = ClipboardEntry(
                kind: .text,
                text: "fixture",
                contentHash: UUID().uuidString,
                isPinned: isPinned,
                pinnedOrder: pinnedOrder,
                isDesktopPinned: isDesktopPinned,
                desktopPinnedOrder: desktopOrder
            )
            let data = try encoder.encode(entry)
            let decoded = try decoder.decode(ClipboardEntry.self, from: data)

            XCTAssertEqual(decoded.isPinned, isPinned)
            XCTAssertEqual(decoded.pinnedOrder, pinnedOrder)
            XCTAssertEqual(decoded.isDesktopPinned, isDesktopPinned)
            XCTAssertEqual(decoded.desktopPinnedOrder, desktopOrder)
            XCTAssertEqual(decoded, entry)
            XCTAssertEqual(decoded.hashValue, entry.hashValue)
        }
    }

    func testPinnedStateDoesNotChangeContentOrSourceProjection() {
        var entry = ClipboardEntry(
            kind: .text,
            text: "unchanged",
            contentHash: "pin-content",
            sourceApp: "Notes",
            sourceBundleIdentifier: "com.apple.Notes"
        )
        let sourceBox = entry.sourceMetadataBoxForInterning

        entry.isPinned = true
        entry.pinnedOrder = 0
        entry.isDesktopPinned = true
        entry.desktopPinnedOrder = 1

        XCTAssertEqual(entry.text, "unchanged")
        XCTAssertEqual(entry.sourceApp, "Notes")
        XCTAssertEqual(entry.sourceBundleIdentifier, "com.apple.Notes")
        XCTAssertTrue(entry.sourceMetadataBoxForInterning === sourceBox)
    }
}
