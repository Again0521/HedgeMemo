import XCTest
@testable import HedgeMemoCore

final class SemanticVersionTests: XCTestCase {
    func testParsesRepositoryReleaseTag() throws {
        let version = try XCTUnwrap(SemanticVersion("v1.1.0-release"))
        XCTAssertEqual(version.components, [1, 1, 0])
        XCTAssertEqual(version.displayString, "1.1.0")
    }

    func testComparesEachComponentNumerically() throws {
        XCTAssertGreaterThan(
            try XCTUnwrap(SemanticVersion("1.10.0")),
            try XCTUnwrap(SemanticVersion("1.9.99"))
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(SemanticVersion("99.99.99")),
            try XCTUnwrap(SemanticVersion("10.100.100"))
        )
    }

    func testMissingTrailingComponentsCompareAsZero() throws {
        XCTAssertEqual(
            try XCTUnwrap(SemanticVersion("v1.1")),
            try XCTUnwrap(SemanticVersion("1.1.0"))
        )
    }

    func testRejectsMalformedVersions() {
        XCTAssertNil(SemanticVersion("release-1.1.0"))
        XCTAssertNil(SemanticVersion("v1..0-release"))
        XCTAssertNil(SemanticVersion("v-release"))
    }

    func testAutomaticCheckRunsOncePerLocalCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 8)))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 22)))
        let nextMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8)))

        XCTAssertFalse(UpdateReminderPolicy.shouldCheckAutomatically(lastCheck: morning, now: evening, calendar: calendar))
        XCTAssertTrue(UpdateReminderPolicy.shouldCheckAutomatically(lastCheck: morning, now: nextMorning, calendar: calendar))
        XCTAssertTrue(UpdateReminderPolicy.shouldCheckAutomatically(lastCheck: nil, now: morning, calendar: calendar))
    }

    func testEachReleaseBadgeAppearsOnlyUntilThatVersionIsAcknowledged() throws {
        let release = try XCTUnwrap(SemanticVersion("1.10.0"))
        XCTAssertTrue(UpdateReminderPolicy.shouldShowBadge(release: release, acknowledged: nil))
        XCTAssertFalse(UpdateReminderPolicy.shouldShowBadge(release: release, acknowledged: release))
        XCTAssertTrue(UpdateReminderPolicy.shouldShowBadge(
            release: try XCTUnwrap(SemanticVersion("1.10.1")),
            acknowledged: release
        ))
    }
}
