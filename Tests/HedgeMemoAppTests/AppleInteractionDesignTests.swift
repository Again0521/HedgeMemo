import CoreGraphics
import XCTest

@testable import HedgeMemo

final class AppleInteractionDesignTests: XCTestCase {
    func testMemeDragPreservesTheOriginalGrabPoint() {
        let center = MemeDragGeometry.tileCenter(
            index: 5,
            columnCount: 4,
            tileSide: 92,
            spacing: 8
        )
        XCTAssertEqual(center, CGPoint(x: 146, y: 146))

        let start = CGPoint(x: 125, y: 132)
        let offset = MemeDragGeometry.grabOffset(
            startLocation: start,
            tileCenter: center
        )
        XCTAssertEqual(offset, CGSize(width: -21, height: -14))

        let pointer = CGPoint(x: 205, y: 242)
        let floatingCenter = MemeDragGeometry.floatingCenter(
            pointerLocation: pointer,
            grabOffset: offset
        )
        XCTAssertEqual(floatingCenter, CGPoint(x: 226, y: 256))
        XCTAssertEqual(
            CGSize(
                width: pointer.x - floatingCenter.x,
                height: pointer.y - floatingCenter.y
            ),
            offset
        )
    }
}
