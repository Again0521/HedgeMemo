import AppKit
import XCTest

@testable import HedgeMemo

final class MemeImageImportTests: XCTestCase {
    func testFolderImportConsumesOnePayloadAtATimeAndDeduplicatesOverlappingSelections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-image-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try XCTUnwrap(NSImage(systemSymbolName: "star", accessibilityDescription: nil)?.pngData)
            .write(to: first)
        try XCTUnwrap(NSImage(systemSymbolName: "heart", accessibilityDescription: nil)?.pngData)
            .write(to: second)

        var consumedFileSizes: [Int] = []
        let count = MemeImageImport.forEachPayload(from: [root, first]) { payload in
            consumedFileSizes.append(payload.data.count)
        }

        XCTAssertEqual(count, 2)
        XCTAssertEqual(consumedFileSizes.count, 2)
        XCTAssertTrue(consumedFileSizes.allSatisfy { $0 > 0 })
    }
}
