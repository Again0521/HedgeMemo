import Foundation
import XCTest
@testable import HedgeMemoCore

final class CompactContentHashTests: XCTestCase {
    func testCanonicalSHA256UsesInlineWordsAndRoundTripsExactly() {
        let value = String(repeating: "0123456789abcdef", count: 4)
        let compact = CompactContentHash(value)

        XCTAssertTrue(compact.usesInlineSHA256Storage)
        XCTAssertEqual(compact.stringValue, value)
        XCTAssertLessThanOrEqual(
            CompactContentHash.storageStride,
            40,
            "the canonical digest must remain four inline words, not a boxed byte buffer"
        )
    }

    func testNonCanonicalAndUppercaseLegacyValuesRemainVerbatim() {
        for value in [
            "legacy-content-hash",
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
            String(repeating: "0", count: 63),
        ] {
            let compact = CompactContentHash(value)
            XCTAssertFalse(compact.usesInlineSHA256Storage)
            XCTAssertEqual(compact.stringValue, value)
        }
    }

    func testArchiveDedupKeysKeepCanonicalHashesBinaryAndCollisionFree() {
        let canonicalValue = String(repeating: "0123456789abcdef", count: 4)
        let canonical = CompactContentHash(canonicalValue)
        let ordinary = canonical.archiveDedupKey(isSecret: false)
        let secret = canonical.archiveDedupKey(isSecret: true)
        let uppercase = CompactContentHash(
            canonicalValue.uppercased()
        ).archiveDedupKey(isSecret: false)

        XCTAssertEqual(ordinary.count, 34)
        XCTAssertEqual(ordinary.prefix(2), Data([0, 0]))
        XCTAssertEqual(secret.count, 34)
        XCTAssertEqual(secret.prefix(2), Data([1, 0]))
        XCTAssertNotEqual(ordinary, secret)
        XCTAssertEqual(uppercase.prefix(2), Data([0, 1]))
        XCTAssertEqual(uppercase.count, 66)
        XCTAssertNotEqual(ordinary, uppercase)
    }

    func testTenThousandCanonicalArchiveKeysStayAtThirtyFourBytes() {
        var keys = Set<Data>()
        keys.reserveCapacity(10_000)

        for index in 0..<10_000 {
            let suffix = String(index, radix: 16)
            let hash = String(repeating: "0", count: 64 - suffix.count) + suffix
            let key = CompactContentHash(hash).archiveDedupKey(
                isSecret: index.isMultiple(of: 2)
            )
            XCTAssertEqual(key.count, 34)
            keys.insert(key)
        }

        XCTAssertEqual(keys.count, 10_000)
    }

    func testModelsKeepStringAPIAndCodableFormatWhileCompactingRealHashes() throws {
        let hash = Data("compact model hash".utf8).clipboardContentHash
        var meme = MemeItem(
            fileName: "compact.png",
            contentHash: hash,
            note: "unchanged"
        )
        var clipboard = ClipboardEntry(
            kind: .text,
            text: "unchanged",
            contentHash: hash
        )

        XCTAssertTrue(meme.compactContentHash.usesInlineSHA256Storage)
        XCTAssertTrue(clipboard.compactContentHash.usesInlineSHA256Storage)
        XCTAssertEqual(meme.contentHash, hash)
        XCTAssertEqual(clipboard.contentHash, hash)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decodedMeme = try decoder.decode(
            MemeItem.self,
            from: encoder.encode(meme)
        )
        let decodedClipboard = try decoder.decode(
            ClipboardEntry.self,
            from: encoder.encode(clipboard)
        )
        XCTAssertEqual(decodedMeme.contentHash, hash)
        XCTAssertEqual(decodedClipboard.contentHash, hash)
        XCTAssertTrue(decodedMeme.compactContentHash.usesInlineSHA256Storage)
        XCTAssertTrue(decodedClipboard.compactContentHash.usesInlineSHA256Storage)

        meme.contentHash = "legacy-meme-hash"
        clipboard.contentHash = "legacy-clipboard-hash"
        XCTAssertEqual(meme.contentHash, "legacy-meme-hash")
        XCTAssertEqual(clipboard.contentHash, "legacy-clipboard-hash")
        XCTAssertFalse(meme.compactContentHash.usesInlineSHA256Storage)
        XCTAssertFalse(clipboard.compactContentHash.usesInlineSHA256Storage)
    }

    func testTwentyThousandDistinctSHA256ValuesUseNoPerHashStringStorage() {
        var memes: [MemeItem] = []
        var clipboardEntries: [ClipboardEntry] = []
        memes.reserveCapacity(10_000)
        clipboardEntries.reserveCapacity(10_000)

        for index in 0..<10_000 {
            let suffix = String(index, radix: 16)
            let hash = String(repeating: "0", count: 64 - suffix.count) + suffix
            memes.append(
                MemeItem(
                    fileName: "\(index).png",
                    contentHash: hash
                )
            )
            clipboardEntries.append(
                ClipboardEntry(
                    kind: .text,
                    contentHash: hash
                )
            )
        }

        XCTAssertTrue(memes.allSatisfy {
            $0.compactContentHash.usesInlineSHA256Storage
        })
        XCTAssertTrue(clipboardEntries.allSatisfy {
            $0.compactContentHash.usesInlineSHA256Storage
        })
        XCTAssertEqual(Set(memes.map(\.contentHash)).count, 10_000)
        XCTAssertEqual(Set(clipboardEntries.map(\.contentHash)).count, 10_000)
    }
}
