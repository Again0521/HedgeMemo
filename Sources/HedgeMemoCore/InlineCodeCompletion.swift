import Foundation

/// Pure logic behind the code editor's inline "ghost text" completion, kept out
/// of the AppKit text view so it can be tested directly.
///
/// Two rules shape it:
/// 1. **Document words first.** Identifiers the user has already written in the
///    snippet take priority over the built-in keyword vocabulary, so completion
///    reflects the actual code rather than a fixed list.
/// 2. **Smart case.** Matching is case-insensitive, so a lowercase prefix still
///    finds a mixed-case identifier; the returned word keeps its own casing, so
///    accepting it corrects the typed prefix (e.g. `getu` → `getUserName`).
public enum InlineCodeCompletion {
    /// Identifier tokens (`[A-Za-z_][A-Za-z0-9_]*`) of a snippet, with how often
    /// each occurs and the order they first appear.
    public struct Tokens: Sendable, Equatable {
        public let order: [String]
        public let counts: [String: Int]

        public init(order: [String] = [], counts: [String: Int] = [:]) {
            self.order = order
            self.counts = counts
        }
    }

    private static let identifierRegex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")

    public static func tokens(in text: String) -> Tokens {
        let ns = text as NSString
        var counts: [String: Int] = [:]
        var order: [String] = []
        identifierRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range else { return }
            let word = ns.substring(with: range)
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        return Tokens(order: order, counts: counts)
    }

    /// The full word that best completes `partial`, or nil when nothing fits.
    /// `keywords` (assumed lowercase) is consulted only when no document word
    /// matches. Requires at least two typed characters to avoid noise.
    public static func completion(partial: String, tokens: Tokens, keywords: [String]) -> String? {
        guard partial.count >= 2 else { return nil }
        let lowered = partial.lowercased()
        if let word = documentCompletion(partial: partial, lowered: lowered, tokens: tokens) {
            return word
        }
        return keywords.first { $0.count > lowered.count && $0.hasPrefix(lowered) }
    }

    /// Ranking, highest first: an exact-case prefix match beats a
    /// case-insensitive-only one; then a more frequent word; then the shortest
    /// (closest) completion; then the earliest to appear.
    private static func documentCompletion(partial: String, lowered: String, tokens: Tokens) -> String? {
        var best: String?
        var bestExact = false
        var bestCount = 0
        var bestLength = Int.max
        var bestOrder = Int.max
        for (index, word) in tokens.order.enumerated() {
            // Only complete to a *longer* word, which also excludes the
            // in-progress token itself.
            guard word.count > partial.count, word.lowercased().hasPrefix(lowered) else { continue }
            let exact = word.hasPrefix(partial)
            let count = tokens.counts[word] ?? 0
            let length = word.count
            let better: Bool
            if best == nil { better = true }
            else if exact != bestExact { better = exact }
            else if count != bestCount { better = count > bestCount }
            else if length != bestLength { better = length < bestLength }
            else { better = index < bestOrder }
            if better {
                best = word
                bestExact = exact
                bestCount = count
                bestLength = length
                bestOrder = index
            }
        }
        return best
    }
}
