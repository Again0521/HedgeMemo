import Foundation

public enum ClipboardAdvancedSortField: String, Codable, CaseIterable, Sendable {
    case capturedAt
    case lastUsedAt
    case useCount

    public var displayName: String {
        switch self {
        case .capturedAt: L10n.text("录入时间")
        case .lastUsedAt: L10n.text("上次使用时间")
        case .useCount: L10n.text("使用次数")
        }
    }
}

public enum ClipboardSortDirection: String, Codable, CaseIterable, Sendable {
    case descending
    case ascending

    public var displayName: String {
        switch self {
        case .descending: L10n.text("降序")
        case .ascending: L10n.text("升序")
        }
    }

    public var systemImage: String {
        switch self {
        case .descending: "arrow.down"
        case .ascending: "arrow.up"
        }
    }
}

public struct ClipboardAdvancedOptions: Equatable, Hashable, Sendable {
    /// Nil means every source. The sentinel represents entries captured before
    /// stable source metadata existed or while no frontmost app was available.
    public static let unknownSourceIdentifier = "__hedgememo_unknown_source__"

    public var sourceIdentifier: String?
    public var sortField: ClipboardAdvancedSortField
    public var sortDirection: ClipboardSortDirection

    public init(
        sourceIdentifier: String? = nil,
        sortField: ClipboardAdvancedSortField = .capturedAt,
        sortDirection: ClipboardSortDirection = .descending
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sortField = sortField
        self.sortDirection = sortDirection
    }

    public func matchesSource(_ entry: ClipboardEntry) -> Bool {
        guard let sourceIdentifier else { return true }
        guard sourceIdentifier != Self.unknownSourceIdentifier else {
            return entry.sourceApplication == nil
        }
        return entry.sourceApplication?.stableIdentifier == sourceIdentifier
    }

    /// Advanced ordering is used only for ordinary entries; pin partitions are
    /// applied by ClipboardHistoryPolicy before this comparator is consulted.
    public func comesBefore(_ lhs: ClipboardEntry, _ rhs: ClipboardEntry) -> Bool {
        let primary: ComparisonResult
        switch sortField {
        case .capturedAt:
            primary = Self.compare(lhs.createdAt, rhs.createdAt)
        case .lastUsedAt:
            // Never-used entries stay at the end in either direction. They
            // have no meaningful timestamp to compare.
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case (.some(let left), .some(let right)):
                primary = Self.compare(left, right)
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                primary = .orderedSame
            }
        case .useCount:
            primary = Self.compare(lhs.useCount ?? 0, rhs.useCount ?? 0)
        }

        if primary != .orderedSame {
            switch sortDirection {
            case .descending: return primary == .orderedDescending
            case .ascending: return primary == .orderedAscending
            }
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    public var cacheKey: String {
        [
            sourceIdentifier ?? "*",
            sortField.rawValue,
            sortDirection.rawValue,
        ].joined(separator: "\u{2}")
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
