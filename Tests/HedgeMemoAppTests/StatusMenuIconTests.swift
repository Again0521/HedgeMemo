import AppKit
import XCTest

@testable import HedgeMemo

final class StatusMenuIconTests: XCTestCase {
    func testEveryStatusMenuSymbolIsUniqueAndAvailable() {
        XCTAssertEqual(StatusMenuSymbol.allCases.count, 9)
        XCTAssertEqual(Set(StatusMenuSymbol.allCases.map(\.rawValue)).count, 9)

        for symbol in StatusMenuSymbol.allCases {
            XCTAssertNotNil(
                symbol.image(accessibilityDescription: symbol.rawValue),
                "missing status-menu symbol: \(symbol.rawValue)"
            )
        }
    }
}
