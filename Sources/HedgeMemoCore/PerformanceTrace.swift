import os

/// Stable Instruments intervals for the expensive boundaries that matter to
/// interaction latency. Signposts are effectively inert until a trace records
/// them, so production behavior and visuals remain unchanged.
public enum HedgeMemoPerformance {
    private static let signposter = OSSignposter(
        subsystem: "app.hedgememo.HedgeMemo",
        category: "Performance"
    )

    public static func measure<T>(
        _ name: StaticString,
        operation: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }
}
