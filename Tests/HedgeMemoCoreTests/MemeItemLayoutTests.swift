import Foundation
import XCTest
@testable import HedgeMemoCore

final class MemeItemLayoutTests: XCTestCase {
    func testCompactTextStateReducesEveryMemeItemStride() {
        XCTAssertLessThanOrEqual(MemeItem.textStateStorageStride, 8)
        XCTAssertLessThanOrEqual(MemeItem.storageStride, 128)
        XCTAssertGreaterThanOrEqual(
            MemeItem.legacyStorageStrideForTesting - MemeItem.storageStride,
            32
        )

        let itemCount = 10_000
        XCTAssertGreaterThanOrEqual(
            itemCount * (
                MemeItem.legacyStorageStrideForTesting
                    - MemeItem.storageStride
            ),
            320_000
        )
    }

    func testResidentTextBoxesPreserveMemeItemValueSemantics() {
        let original = MemeItem(
            fileName: "value.gif",
            contentHash: "value",
            note: "original note",
            ocrText: "original OCR"
        )
        var edited = original

        edited.note = "edited note"
        edited.ocrText = "edited OCR"

        XCTAssertEqual(original.note, "original note")
        XCTAssertEqual(original.ocrText, "original OCR")
        XCTAssertEqual(edited.note, "edited note")
        XCTAssertEqual(edited.ocrText, "edited OCR")
    }

    func testDeferredCopyCanBecomeResidentWithoutChangingItsSource() {
        let id = UUID()
        let provider = MemeTextProvider { requestedID in
            guard requestedID == id else { return nil }
            return MemeTextBody(
                note: "database note",
                ocrText: "database OCR"
            )
        }
        var deferred = MemeItem(
            id: id,
            fileName: "deferred.gif",
            contentHash: "deferred"
        )
        deferred.deferText(to: provider)
        var edited = deferred

        edited.note = "local note"

        XCTAssertEqual(deferred.decodedStoredTextByteCount, 0)
        XCTAssertEqual(deferred.note, "database note")
        XCTAssertEqual(deferred.ocrText, "database OCR")
        XCTAssertEqual(edited.note, "local note")
        XCTAssertEqual(edited.ocrText, "database OCR")
        XCTAssertGreaterThan(edited.decodedStoredTextByteCount, 0)
    }

    func testMetadataProjectionAndCodableFieldsRemainUnchanged() throws {
        let original = MemeItem(
            fileName: "metadata.gif",
            contentHash: "metadata",
            note: "visible note",
            ocrText: "visible OCR"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let projectionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(original.metadataProjection)
            ) as? [String: Any]
        )
        XCTAssertEqual(projectionObject["note"] as? String, "")
        XCTAssertEqual(projectionObject["ocrText"] as? String, "")
        XCTAssertEqual(original.note, "visible note")
        XCTAssertEqual(original.ocrText, "visible OCR")

        let decoded = try decoder.decode(
            MemeItem.self,
            from: encoder.encode(original)
        )
        XCTAssertEqual(decoded.note, original.note)
        XCTAssertEqual(decoded.ocrText, original.ocrText)
        XCTAssertEqual(decoded.fileName, original.fileName)
        XCTAssertEqual(decoded.contentHash, original.contentHash)
    }

    func testTenThousandDeferredItemsRetainNoResidentBodyBytes() {
        let provider = MemeTextProvider { _ in
            MemeTextBody(note: "lazy note", ocrText: "lazy OCR")
        }
        var items: [MemeItem] = []
        items.reserveCapacity(10_000)
        for index in 0..<10_000 {
            var item = MemeItem(
                fileName: "\(index).gif",
                contentHash: "layout-\(index)",
                note: "resident-\(index)",
                ocrText: "resident-ocr-\(index)"
            )
            item.deferText(to: provider)
            items.append(item)
        }

        XCTAssertTrue(items.allSatisfy {
            $0.decodedStoredTextByteCount == 0
        })
        XCTAssertEqual(items[9_999].note, "lazy note")
        XCTAssertEqual(items[9_999].ocrText, "lazy OCR")
    }
}
