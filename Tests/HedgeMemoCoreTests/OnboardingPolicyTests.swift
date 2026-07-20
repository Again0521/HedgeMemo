import XCTest

@testable import HedgeMemoCore

/// Covers the first-run seeding decision: seed only a genuine fresh install,
/// and never more than once.
final class OnboardingPolicyTests: XCTestCase {
    func testFreshInstallSeeds() {
        XCTAssertTrue(OnboardingPolicy.shouldSeed(hasDecidedBefore: false, hasExistingData: false))
    }

    func testUpdateWithExistingDataIsNotSeeded() {
        // A user updating from a pre-seeding version already has data on disk.
        XCTAssertFalse(OnboardingPolicy.shouldSeed(hasDecidedBefore: false, hasExistingData: true))
    }

    func testAlreadyDecidedIsNeverSeededAgain() {
        // Once the decision has run, deleting a sample must not bring it back.
        XCTAssertFalse(OnboardingPolicy.shouldSeed(hasDecidedBefore: true, hasExistingData: false))
        XCTAssertFalse(OnboardingPolicy.shouldSeed(hasDecidedBefore: true, hasExistingData: true))
    }
}
