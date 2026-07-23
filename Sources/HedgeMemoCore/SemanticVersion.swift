import Foundation

/// Numeric dotted-version comparison used by the GitHub release checker.
/// Accepts repository tags such as `v1.1.0-release` without ever comparing
/// version components lexicographically (`1.10.0` must be newer than `1.9.99`).
public struct SemanticVersion: Equatable, Comparable, Sendable {
    public let components: [Int]

    public init?(_ rawValue: String) {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.first?.lowercased() == "v" {
            candidate.removeFirst()
        }
        let numericPrefix = candidate.prefix { $0.isNumber || $0 == "." }
        let parts = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        let parsed = parts.compactMap { Int($0) }
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty }),
              parsed.count == parts.count else { return nil }
        components = parsed
    }

    public var displayString: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public enum UpdateReminderPolicy {
    public static func shouldCheckAutomatically(
        lastCheck: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let lastCheck else { return true }
        return !calendar.isDate(lastCheck, inSameDayAs: now)
    }

    public static func shouldShowBadge(
        release: SemanticVersion,
        acknowledged: SemanticVersion?
    ) -> Bool {
        acknowledged.map { release > $0 } ?? true
    }
}
