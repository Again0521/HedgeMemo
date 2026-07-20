import Foundation

/// Decides whether first-run content (sample memes, guidance entries) should be
/// seeded. The rules keep two promises:
///
/// 1. Only a *genuine fresh install* is seeded — a user updating from a version
///    that predates seeding already has data on disk and must not suddenly get
///    sample content dropped into their library.
/// 2. The decision is made exactly once. After it runs, deleting a sample never
///    brings it back on the next launch or a later update.
public enum OnboardingPolicy {
    /// - Parameters:
    ///   - hasDecidedBefore: whether the one-time seed decision has already run.
    ///   - hasExistingData: whether any prior user data exists (which means this
    ///     launch is an update, not a first install).
    public static func shouldSeed(hasDecidedBefore: Bool, hasExistingData: Bool) -> Bool {
        !hasDecidedBefore && !hasExistingData
    }
}
