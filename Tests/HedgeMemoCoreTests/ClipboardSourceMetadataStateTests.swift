import Foundation
import XCTest
@testable import HedgeMemoCore

@MainActor
final class ClipboardSourceMetadataStateTests: XCTestCase {
    func testSharedSourceStateReducesEveryClipboardEntryStride() {
        XCTAssertEqual(ClipboardEntry.sourceMetadataStorageStride, 8)
        XCTAssertLessThanOrEqual(ClipboardEntry.storageStride, 208)
        XCTAssertEqual(
            ClipboardEntry.legacySourceStorageStrideForTesting,
            248
        )
        XCTAssertGreaterThanOrEqual(
            ClipboardEntry.legacySourceStorageStrideForTesting
                - ClipboardEntry.storageStride,
            40
        )

        let entryCount = 10_000
        XCTAssertGreaterThanOrEqual(
            entryCount * (
                ClipboardEntry.legacySourceStorageStrideForTesting
                    - ClipboardEntry.storageStride
            ),
            400_000
        )
    }

    func testSourceMutationsPreserveClipboardEntryValueSemantics() {
        let original = ClipboardEntry(
            kind: .text,
            text: "body",
            contentHash: "source-value",
            sourceApp: "Safari",
            sourceBundleIdentifier: "com.apple.Safari",
            sourceBundleURLPath: "/Applications/Safari.app"
        )
        var edited = original

        edited.sourceApp = "Web Browser"
        edited.sourceBundleIdentifier = nil
        edited.sourceBundleURLPath = nil

        XCTAssertEqual(original.sourceApp, "Safari")
        XCTAssertEqual(original.sourceBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(
            original.sourceBundleURLPath,
            "/Applications/Safari.app"
        )
        XCTAssertEqual(edited.sourceApp, "Web Browser")
        XCTAssertNil(edited.sourceBundleIdentifier)
        XCTAssertNil(edited.sourceBundleURLPath)

        edited.sourceApp = nil
        XCTAssertNil(edited.sourceMetadataBoxForInterning)
        XCTAssertNotNil(original.sourceMetadataBoxForInterning)
    }

    func testSourceMetadataKeepsExistingCodableFields() throws {
        let entry = ClipboardEntry(
            kind: .text,
            text: "body",
            contentHash: "source-codable",
            sourceApp: "Notes",
            sourceBundleIdentifier: "com.apple.Notes",
            sourceBundleURLPath: "/System/Applications/Notes.app"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["sourceApp"] as? String, "Notes")
        XCTAssertEqual(
            object["sourceBundleIdentifier"] as? String,
            "com.apple.Notes"
        )
        XCTAssertEqual(
            object["sourceBundleURLPath"] as? String,
            "/System/Applications/Notes.app"
        )

        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: data)
        XCTAssertEqual(decoded.sourceApp, entry.sourceApp)
        XCTAssertEqual(
            decoded.sourceBundleIdentifier,
            entry.sourceBundleIdentifier
        )
        XCTAssertEqual(
            decoded.sourceBundleURLPath,
            entry.sourceBundleURLPath
        )
        XCTAssertEqual(decoded.sourceApplication, entry.sourceApplication)
    }

    func testTenThousandRepeatedSourcesShareOneMetadataBox() throws {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(
                rootURL: temporaryURL("shared-source")
            )
        )
        let entries = (0..<10_000).map { index in
            ClipboardEntry(
                kind: .text,
                text: "body-\(index)",
                contentHash: "source-\(index)",
                sourceApp: independentlyDecoded("Example Browser"),
                sourceBundleIdentifier: independentlyDecoded(
                    "com.example.browser"
                ),
                sourceBundleURLPath: independentlyDecoded(
                    "/Applications/Example Browser.app"
                )
            )
        }

        store.injectPreviewEntries(entries)

        let identities = Set(store.entries.compactMap {
            $0.sourceMetadataBoxForInterning.map(ObjectIdentifier.init)
        })
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(
            store.sourceStringInternerMetrics.uniqueSourceMetadataCount,
            1
        )
        XCTAssertEqual(
            store.sourceStringInternerMetrics.peakUniqueSourceMetadataCount,
            1
        )
        XCTAssertTrue(store.entries.allSatisfy {
            $0.sourceApplication?.stableIdentifier
                == "bundle:com.example.browser"
        })
    }

    func testDistinctSourcesAreNotCoalesced() throws {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(
                rootURL: temporaryURL("distinct-source")
            )
        )
        store.injectPreviewEntries([
            ClipboardEntry(
                kind: .text,
                text: "one",
                contentHash: "one",
                sourceApp: "One",
                sourceBundleIdentifier: "com.example.one"
            ),
            ClipboardEntry(
                kind: .text,
                text: "two",
                contentHash: "two",
                sourceApp: "Two",
                sourceBundleIdentifier: "com.example.two"
            ),
        ])

        XCTAssertEqual(
            Set(store.entries.compactMap {
                $0.sourceMetadataBoxForInterning.map(ObjectIdentifier.init)
            }).count,
            2
        )
        XCTAssertEqual(
            store.sourceStringInternerMetrics.uniqueSourceMetadataCount,
            2
        )
    }

    func testSourceMetadataInternerStaysBoundedForTenThousandUniqueSources() throws {
        let store = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(
                rootURL: temporaryURL("bounded-source")
            )
        )
        let entries = (0..<10_000).map { index in
            ClipboardEntry(
                kind: .text,
                text: "body-\(index)",
                contentHash: "unique-source-\(index)",
                sourceApp: "Application \(index)",
                sourceBundleIdentifier: "com.example.application-\(index)"
            )
        }

        store.injectPreviewEntries(entries)

        XCTAssertLessThanOrEqual(
            store.sourceStringInternerMetrics.uniqueSourceMetadataCount,
            1_024
        )
        XCTAssertLessThanOrEqual(
            store.sourceStringInternerMetrics.peakUniqueSourceMetadataCount,
            1_024
        )
        XCTAssertEqual(store.entries.count, 10_000)
        XCTAssertEqual(store.entries.last?.sourceApp, "Application 9999")
    }

    func testEntriesWithoutSourcesAllocateNoMetadataBox() {
        let entries = (0..<10_000).map { index in
            ClipboardEntry(
                kind: .text,
                text: "body-\(index)",
                contentHash: "no-source-\(index)"
            )
        }

        XCTAssertTrue(entries.allSatisfy {
            $0.sourceMetadataBoxForInterning == nil
        })
    }

    private func independentlyDecoded(_ value: String) -> String {
        String(data: Data(value.utf8), encoding: .utf8)!
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HedgeMemo-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
