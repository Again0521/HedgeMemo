import Foundation

/// Case-insensitive fuzzy matching with `%` as an ordered-fragment wildcard.
/// Queries are implicitly fuzzy on both ends, so `jav%` can match text that has
/// characters before `jav`; `%` is useful for requiring separated fragments
/// such as `java%script`. Queries without `%` retain contains behavior.
public struct PercentFuzzyMatcher: Sendable {
    private let pattern: String
    private let fragments: [String]
    private let hasWildcard: Bool

    public init(query: String) {
        pattern = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasWildcard = pattern.contains("%")
        fragments = hasWildcard
            ? pattern.split(separator: "%", omittingEmptySubsequences: false).map(String.init)
            : []
    }

    public func matches(_ candidate: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard hasWildcard else { return candidate.localizedCaseInsensitiveContains(pattern) }

        let options: String.CompareOptions = [.caseInsensitive]
        var cursor = candidate.startIndex
        var lastMatch: Range<String.Index>?

        for fragment in fragments where !fragment.isEmpty {
            guard let match = candidate.range(of: fragment, options: options, range: cursor..<candidate.endIndex) else {
                return false
            }
            lastMatch = match
            cursor = match.upperBound
        }

        // A pattern made only from `%` characters matches everything.
        return lastMatch != nil || fragments.allSatisfy(\.isEmpty)
    }

    public static func matches(_ candidate: String, query: String) -> Bool {
        Self(query: query).matches(candidate)
    }
}

public struct MemeCategory: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct MemeItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var fileName: String
    public var contentHash: String
    public var note: String
    public var ocrText: String
    public var categoryID: UUID?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        contentHash: String,
        note: String = "未命名",
        ocrText: String = "",
        categoryID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fileName = fileName
        self.contentHash = contentHash
        self.note = note
        self.ocrText = ocrText
        self.categoryID = categoryID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func matches(query: String) -> Bool {
        matches(matcher: PercentFuzzyMatcher(query: query))
    }

    public func matches(matcher: PercentFuzzyMatcher) -> Bool {
        matcher.matches(note) || matcher.matches(ocrText)
    }
}

public struct MemeSnapshot: Codable, Sendable {
    public var categories: [MemeCategory]
    public var memes: [MemeItem]

    public init(categories: [MemeCategory] = [], memes: [MemeItem] = []) {
        self.categories = categories
        self.memes = memes
    }
}

public enum MemeFilter {
    public static func apply(_ memes: [MemeItem], categoryID: UUID?, query: String) -> [MemeItem] {
        let matcher = PercentFuzzyMatcher(query: query)
        return memes
            .filter { categoryID == nil || $0.categoryID == categoryID }
            .filter { $0.matches(matcher: matcher) }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder { return lhs.createdAt < rhs.createdAt }
                return lhs.sortOrder < rhs.sortOrder
            }
    }
}

public enum ClipboardEntryKind: String, Codable, Sendable {
    case text
    case image
}

/// Built-in clipboard categories. The case order is the default display order.
public enum ClipboardContentCategory: String, Codable, CaseIterable, Sendable {
    case text
    case code
    case link
    case image
    case screenshot

    public var displayName: String {
        switch self {
        case .text: "文本"
        case .code: "代码"
        case .link: "链接"
        case .image: "图片"
        case .screenshot: "截图"
        }
    }

    public var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .image: "photo"
        case .screenshot: "camera.viewfinder"
        }
    }
}

/// The source is optional so snapshots written before screenshot separation
/// continue to decode as ordinary image entries.
public enum ClipboardEntryOrigin: String, Codable, Sendable {
    // The raw value is persisted in clipboard-history.json and ZIP manifests;
    // it keeps the pre-rename (MemeMemo era) spelling so existing snapshots
    // and archives continue to decode after the HedgeMemo rename.
    case hedgeMemoScreenshot = "memeMemoScreenshot"
}

/// User-defined category that filters text entries with a regular expression.
public struct CustomClipboardCategory: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var pattern: String

    public init(id: UUID = UUID(), name: String, pattern: String) {
        self.id = id
        self.name = name
        self.pattern = pattern
    }

    public var isPatternValid: Bool {
        !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) != nil
    }

    public func matches(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

/// Identifies either a built-in category or a custom regex category,
/// with a stable string form for persistence ("text", "custom:<uuid>", ...).
public enum ClipboardCategoryKey: Hashable, Sendable {
    case builtin(ClipboardContentCategory)
    case custom(UUID)

    private static let customPrefix = "custom:"

    public var storageValue: String {
        switch self {
        case .builtin(let category): category.rawValue
        case .custom(let id): Self.customPrefix + id.uuidString
        }
    }

    public init?(storageValue: String) {
        if let category = ClipboardContentCategory(rawValue: storageValue) {
            self = .builtin(category)
        } else if storageValue.hasPrefix(Self.customPrefix),
                  let id = UUID(uuidString: String(storageValue.dropFirst(Self.customPrefix.count))) {
            self = .custom(id)
        } else {
            return nil
        }
    }
}

public enum ClipboardLinkDetector {
    public static func isLink(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isNewline), !text.contains(" ") else { return false }
        let lowered = text.lowercased()
        let prefixes = ["http://", "https://", "ftp://", "magnet:", "mailto:", "file://", "www."]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        // Bare domains like example.com/path
        return lowered.range(of: "^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}(/\\S*)?$", options: .regularExpression) != nil
    }
}

/// Heuristic classifier that separates pasted source code from ordinary prose.
/// Scores independent signals so that no single one (a lone brace, a lone colon)
/// is enough to call something code.
public enum ClipboardCodeDetector {
    private static let keywords = [
        "func ", "function ", "class ", "def ", "return ", "import ", "#include", "#define",
        "var ", "let ", "const ", "public ", "private ", "static ", "struct ", "enum ",
        "interface ", "package ", "extends ", "implements ", "async ", "await ", "yield ",
        "console.log", "print(", "printf(", "println(", "system.out",
        "select ", "insert into", "update ", "delete from", "where ", "<?php", "#!/",
    ]

    private static let operators = ["=>", "->", "::", "&&", "||", "==", "!=", ">=", "<=", "+=", "??"]

    /// Common English function words. A run of ordinary prose is dense with
    /// these; source code almost never is. Deliberately excludes words that
    /// double as code keywords (`return`, `class`, `public`, `where`, …) so a
    /// real statement isn't mistaken for prose.
    private static let proseWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be", "been",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "this", "these",
        "those", "it", "its", "you", "your", "we", "our", "they", "their", "he", "she",
        "his", "her", "i", "me", "my", "not", "no", "yes", "if", "so", "because", "about",
        "into", "over", "after", "before", "when", "while", "who", "how", "why", "can",
        "could", "will", "would", "should", "may", "might", "must", "do", "does", "did",
        "have", "has", "had", "please", "thanks", "thank", "just", "also", "only", "very",
        "really", "more", "most", "some", "any", "all", "every", "one", "two", "get",
        "make", "use", "like", "want", "need", "see", "know", "think", "time", "people",
        "way", "here", "there", "out", "up", "down", "them", "then", "than",
    ]

    public static func isCode(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else { return false }
        guard !isLikelyLink(text) else { return false }
        guard cjkRatio(text) <= 0.3 else { return false }
        // Unambiguous structure (braces, terminators, comments, operators, high
        // symbol density) is code regardless of any incidental English words.
        if hasHardCodeStructure(text) { return score(text) >= 3 }
        // Without that structure, a keyword or a stray parenthesis is not enough
        // on its own: long English prose borrows words like "return", "public"
        // and "where". If the text reads as sentences, treat it as prose.
        if looksLikeProse(text) { return false }
        return score(text) >= 3
    }

    /// Whether the text reads as natural-language prose rather than code.
    /// English is dense with common function words ("the", "is", "to", …) that
    /// code almost never uses; several distinct ones, or a high proportion of
    /// them across a longer run, is a decisive prose signal.
    private static func looksLikeProse(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard words.count >= 4 else { return false }
        var distinct = Set<String>()
        var hits = 0
        for word in words where proseWords.contains(word) {
            hits += 1
            distinct.insert(word)
        }
        if distinct.count >= 3 { return true }
        return words.count >= 6 && Double(hits) / Double(words.count) >= 0.25
    }

    /// Structural markers that prose effectively never produces: statement
    /// terminators/braces, code operators, comments, a brace pair, or a high
    /// symbol density. Deliberately omits weaker signals that do appear in prose
    /// — a `word(` call (English writes "item(s)", "file(s)") and `[...]` pairs.
    private static func hasHardCodeStructure(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        if lines.contains(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed.hasSuffix("):")
        }) { return true }
        if operators.contains(where: { text.contains($0) }) { return true }
        if text.contains("//") || text.contains("/*") || text.contains("*/") || text.contains("#!") { return true }
        if text.contains("{") && text.contains("}") { return true }
        return symbolRatio(text) > 0.15
    }

    private static func score(_ text: String) -> Int {
        let lowered = text.lowercased()
        let lines = text.components(separatedBy: .newlines)
        var score = 0

        if keywords.contains(where: { lowered.contains($0) }) { score += 2 }
        if operators.contains(where: { text.contains($0) }) { score += 1 }
        if lines.contains(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed.hasSuffix("):")
        }) { score += 2 }
        if text.contains("{") && text.contains("}") { score += 1 }
        if text.contains("(") && text.contains(")") { score += 1 }
        if lines.count > 1, lines.contains(where: { $0.hasPrefix("  ") || $0.hasPrefix("\t") }) { score += 1 }
        if lines.contains(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("#!")
        }) { score += 1 }
        if symbolRatio(text) > 0.08 { score += 1 }
        return score
    }

    private static func isLikelyLink(_ text: String) -> Bool {
        ClipboardLinkDetector.isLink(text)
    }

    private static func cjkRatio(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let cjk = letters.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }
        return Double(cjk.count) / Double(letters.count)
    }

    private static func symbolRatio(_ text: String) -> Double {
        let symbols = CharacterSet(charactersIn: "{}()[];<>=+*/%&|!$#@\\_")
        let meaningful = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !meaningful.isEmpty else { return 0 }
        let hits = meaningful.filter { symbols.contains($0) }
        return Double(hits.count) / Double(meaningful.count)
    }
}

public enum ClipboardItemSize: String, Codable, CaseIterable, Sendable {
    case compact
    case regular
    case large

    public var displayName: String {
        switch self {
        case .compact: "紧凑"
        case .regular: "标准"
        case .large: "大"
        }
    }
}

public struct HotKeyDefinition: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        keyCode: UInt32,
        key: String,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    public static let defaultClipboard = HotKeyDefinition(keyCode: 9, key: "V", command: true, shift: true)
    /// The pre-⇧⌘V default; persisted settings still carrying it are migrated forward.
    public static let legacyClipboard = HotKeyDefinition(keyCode: 49, key: "Space", option: true)
    /// Screenshot's default shortcut is ⇧⌘P. Keep the prior shortcut as a
    /// migration sentinel so existing default settings move forward once.
    public static let defaultScreenshot = HotKeyDefinition(keyCode: 35, key: "P", command: true, shift: true)
    public static let legacyScreenshot = HotKeyDefinition(keyCode: 23, key: "5", control: true, shift: true)

    public var isUsable: Bool {
        keyCode > 0 && !key.isEmpty && (command || option || control || shift)
    }

    public var displayName: String {
        var parts = [String]()
        if command { parts.append("Command") }
        if option { parts.append("Option") }
        if control { parts.append("Control") }
        if shift { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: " + ")
    }
}

public enum HotKeyPolicy {
    public static func conflicts(_ lhs: HotKeyDefinition, _ rhs: HotKeyDefinition) -> Bool {
        lhs.isUsable && rhs.isUsable && lhs == rhs
    }

    public static func label(_ hotKey: HotKeyDefinition?) -> String {
        guard let hotKey, hotKey.isUsable else { return "未设置" }
        return hotKey.displayName
    }
}

public enum CodeHighlightTheme: String, Codable, CaseIterable, Sendable {
    /// The existing macOS-adaptive palette, retained as the default.
    case system
    case xcodeLight
    case solarizedLight
    case githubLight

    public var displayName: String {
        switch self {
        case .system: "系统彩色"
        case .xcodeLight: "Xcode 浅色"
        case .solarizedLight: "Solarized 浅色"
        case .githubLight: "GitHub 浅色"
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .system: "使用 macOS 自适应的蓝绿紫语法颜色"
        case .xcodeLight: "使用接近 Xcode 的高对比浅色配色"
        case .solarizedLight: "使用低对比、护眼的 Solarized 浅色配色"
        case .githubLight: "使用 GitHub 风格的清晰浅色配色"
        }
    }
}

public struct ClipboardHistorySettings: Codable, Equatable, Sendable {
    public static let maxEntryChoices = [100, 200, 300, 500, 700, 1_000, 2_000, 3_000, 5_000, 7_000, 10_000]

    public var maxEntries: Int
    public var savesImages: Bool
    public var itemSize: ClipboardItemSize
    public var autoPaste: Bool
    public var hotKey: HotKeyDefinition?
    // Optional so snapshots written before these fields existed still decode.
    // `lastCategory` and `categoryOrder` hold ClipboardCategoryKey storage values.
    public var lastCategory: String?
    public var categoryOrder: [String]?
    public var customCategories: [CustomClipboardCategory]?
    /// Storage values of categories disabled by the user. Optional preserves
    /// source compatibility with snapshots from before category switches.
    public var disabledCategoryKeys: [String]?
    /// Optional preserves decoding of settings saved before syntax themes
    /// existed. Nil maps to the original system palette.
    public var codeHighlightTheme: CodeHighlightTheme?

    public init(
        maxEntries: Int = 100,
        savesImages: Bool = true,
        itemSize: ClipboardItemSize = .regular,
        autoPaste: Bool = false,
        hotKey: HotKeyDefinition? = .defaultClipboard,
        lastCategory: String? = ClipboardCategoryKey.builtin(.text).storageValue,
        categoryOrder: [String]? = nil,
        customCategories: [CustomClipboardCategory]? = nil,
        disabledCategoryKeys: [String]? = nil,
        codeHighlightTheme: CodeHighlightTheme? = .system
    ) {
        self.maxEntries = Self.normalizedMaxEntries(maxEntries)
        self.savesImages = savesImages
        self.itemSize = itemSize
        self.autoPaste = autoPaste
        self.hotKey = hotKey
        self.lastCategory = lastCategory
        self.categoryOrder = categoryOrder
        self.customCategories = customCategories
        self.disabledCategoryKeys = disabledCategoryKeys
        self.codeHighlightTheme = codeHighlightTheme
        normalize()
    }

    public var resolvedCodeHighlightTheme: CodeHighlightTheme {
        codeHighlightTheme ?? .system
    }

    public var activeCategoryKey: ClipboardCategoryKey {
        get { lastCategory.flatMap(ClipboardCategoryKey.init(storageValue:)) ?? .builtin(.text) }
        set { lastCategory = newValue.storageValue }
    }

    public var orderedCategoryKeys: [ClipboardCategoryKey] {
        (categoryOrder ?? []).compactMap(ClipboardCategoryKey.init(storageValue:))
    }

    public var enabledCategoryKeys: [ClipboardCategoryKey] {
        orderedCategoryKeys.filter { isCategoryEnabled($0) }
    }

    public func isCategoryEnabled(_ key: ClipboardCategoryKey) -> Bool {
        !(disabledCategoryKeys ?? []).contains(key.storageValue)
    }

    public mutating func setCategory(_ key: ClipboardCategoryKey, enabled: Bool) {
        var disabled = Set(disabledCategoryKeys ?? [])
        if enabled {
            disabled.remove(key.storageValue)
        } else {
            disabled.insert(key.storageValue)
        }
        disabledCategoryKeys = disabled.sorted()
    }

    public func customCategory(id: UUID) -> CustomClipboardCategory? {
        customCategories?.first(where: { $0.id == id })
    }

    public mutating func normalize() {
        maxEntries = Self.normalizedMaxEntries(maxEntries)
        if hotKey == nil || hotKey == .legacyClipboard { hotKey = .defaultClipboard }
        let customs = customCategories ?? []
        customCategories = customs

        func isValid(_ key: ClipboardCategoryKey) -> Bool {
            switch key {
            case .builtin: true
            case .custom(let id): customs.contains(where: { $0.id == id })
            }
        }

        // Keep the user's order, drop stale keys, then append anything missing:
        // built-ins in their default order first, then remaining custom categories.
        var seen = Set<String>()
        var order = (categoryOrder ?? [])
            .compactMap(ClipboardCategoryKey.init(storageValue:))
            .filter { isValid($0) && seen.insert($0.storageValue).inserted }
        for category in ClipboardContentCategory.allCases where seen.insert(category.rawValue).inserted {
            order.append(.builtin(category))
        }
        for custom in customs {
            let key = ClipboardCategoryKey.custom(custom.id)
            if seen.insert(key.storageValue).inserted { order.append(key) }
        }
        categoryOrder = order.map(\.storageValue)
        let validStorageValues = Set(order.map(\.storageValue))
        disabledCategoryKeys = Array(Set(disabledCategoryKeys ?? []).intersection(validStorageValues)).sorted()

        if !isValid(activeCategoryKey) || lastCategory == nil {
            activeCategoryKey = enabledCategoryKeys.first ?? .builtin(.text)
        }
    }

    private static func normalizedMaxEntries(_ value: Int) -> Int {
        maxEntryChoices.min { abs($0 - value) < abs($1 - value) } ?? 100
    }
}

public struct ClipboardEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var kind: ClipboardEntryKind
    public var text: String?
    public var imageFileName: String?
    public var contentHash: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int?
    public var sourceApp: String?
    public var isPinned: Bool
    public var pinnedOrder: Int?
    /// Independent from clipboard ordering/quick-slot pinning. Optional keeps
    /// snapshots written by older versions source-compatible when decoded.
    public var isDesktopPinned: Bool?
    public var origin: ClipboardEntryOrigin?

    public init(
        id: UUID = UUID(),
        kind: ClipboardEntryKind,
        text: String? = nil,
        imageFileName: String? = nil,
        contentHash: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        useCount: Int? = nil,
        sourceApp: String? = nil,
        isPinned: Bool = false,
        pinnedOrder: Int? = nil,
        isDesktopPinned: Bool? = false,
        origin: ClipboardEntryOrigin? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.sourceApp = sourceApp
        self.isPinned = isPinned
        self.pinnedOrder = pinnedOrder
        self.isDesktopPinned = isDesktopPinned
        self.origin = origin
    }

    public var previewText: String {
        switch kind {
        case .text:
            let cleaned = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "空白文字" : cleaned
        case .image:
            return text?.isEmpty == false ? text! : "图片"
        }
    }

    /// Code/link detection scans the whole text with several passes, and the
    /// category is consulted constantly (every list filter asks it for every
    /// entry). Memoized by content hash — the hash always tracks the text
    /// (edits recompute it) — with the text length mixed in to guard against an
    /// accidentally reused hand-written hash across differently sized texts.
    /// NSCache is thread-safe, so this does not affect Sendable-ability.
    nonisolated(unsafe) private static let textCategoryCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4096
        return cache
    }()

    public var contentCategory: ClipboardContentCategory {
        if origin == .hedgeMemoScreenshot { return .screenshot }
        switch kind {
        case .image:
            return .image
        case .text:
            let content = text ?? ""
            let key = "\(contentHash)|\(content.utf8.count)" as NSString
            if let cached = Self.textCategoryCache.object(forKey: key),
               let category = ClipboardContentCategory(rawValue: cached as String) {
                return category
            }
            let category: ClipboardContentCategory
            if ClipboardLinkDetector.isLink(content) {
                category = .link
            } else if ClipboardCodeDetector.isCode(content) {
                category = .code
            } else {
                category = .text
            }
            Self.textCategoryCache.setObject(category.rawValue as NSString, forKey: key)
            return category
        }
    }

    public func matches(query: String) -> Bool {
        matches(matcher: PercentFuzzyMatcher(query: query))
    }

    public func matches(matcher: PercentFuzzyMatcher) -> Bool {
        matcher.matches(previewText)
    }

    public func matches(key: ClipboardCategoryKey?, customCategories: [CustomClipboardCategory] = []) -> Bool {
        switch key {
        case nil:
            return true
        case .builtin(let category):
            return contentCategory == category
        case .custom(let id):
            guard kind == .text, let text,
                  let custom = customCategories.first(where: { $0.id == id }) else { return false }
            return custom.matches(text)
        }
    }
}

public struct ClipboardHistorySnapshot: Codable, Sendable {
    public var entries: [ClipboardEntry]
    public var settings: ClipboardHistorySettings

    public init(entries: [ClipboardEntry] = [], settings: ClipboardHistorySettings = ClipboardHistorySettings()) {
        self.entries = entries
        self.settings = settings
    }
}

public enum ClipboardHistoryPolicy {
    public static func ordered(
        _ entries: [ClipboardEntry],
        query: String = "",
        key: ClipboardCategoryKey? = nil,
        customCategories: [CustomClipboardCategory] = []
    ) -> [ClipboardEntry] {
        let matcher = PercentFuzzyMatcher(query: query)
        return entries
            .filter { $0.matches(matcher: matcher) && $0.matches(key: key, customCategories: customCategories) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                if lhs.isPinned {
                    return (lhs.pinnedOrder ?? Int.max) < (rhs.pinnedOrder ?? Int.max)
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    public static func pinnedEntries(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        ordered(entries).filter(\.isPinned)
    }

    public static func quickEntry(in entries: [ClipboardEntry], number: Int) -> ClipboardEntry? {
        guard (1...9).contains(number) else { return nil }
        let pinned = pinnedEntries(entries)
        guard number <= pinned.count else { return nil }
        return pinned[number - 1]
    }

    public static func shouldMergeWithLatest(latest: ClipboardEntry?, contentHash: String) -> Bool {
        latest?.contentHash == contentHash
    }

    public static func idsToTrim(from entries: [ClipboardEntry], maxEntries: Int) -> [UUID] {
        let maxEntries = max(10, maxEntries)
        guard entries.count > maxEntries else { return [] }
        let orderedEntries = ordered(entries)
        let overflow = orderedEntries.suffix(entries.count - maxEntries)
        return overflow.map(\.id)
    }
}

public enum ScreenshotMode: String, Codable, CaseIterable, Sendable {
    case manualSelection
    case smartWindow

    public var displayName: String {
        switch self {
        case .manualSelection: "手动框选"
        case .smartWindow: "智能窗口"
        }
    }
}

public enum ScreenshotHotKeyChoice: String, Codable, CaseIterable, Sendable {
    case commandShiftP
    case commandShiftFive
    case controlShiftFive

    public var displayName: String {
        switch self {
        case .commandShiftP: "Command + Shift + P"
        case .commandShiftFive: "Command + Shift + 5"
        case .controlShiftFive: "Control + Shift + 5"
        }
    }
}

public struct ScreenshotSettings: Codable, Equatable, Sendable {
    public var mode: ScreenshotMode
    public var remembersLastMode: Bool
    public var hotKeyChoice: ScreenshotHotKeyChoice
    public var opensEditorAfterCapture: Bool
    public var hotKey: HotKeyDefinition?

    public init(
        mode: ScreenshotMode = .smartWindow,
        remembersLastMode: Bool = true,
        hotKeyChoice: ScreenshotHotKeyChoice = .commandShiftP,
        opensEditorAfterCapture: Bool = true,
        hotKey: HotKeyDefinition? = .defaultScreenshot
    ) {
        self.mode = mode
        self.remembersLastMode = remembersLastMode
        self.hotKeyChoice = hotKeyChoice
        self.opensEditorAfterCapture = opensEditorAfterCapture
        self.hotKey = hotKey
        normalize()
    }

    public mutating func normalize() {
        if hotKey == .legacyScreenshot, hotKeyChoice == .controlShiftFive {
            hotKey = .defaultScreenshot
            hotKeyChoice = .commandShiftP
        } else if hotKey == nil {
            hotKey = switch hotKeyChoice {
            case .commandShiftP: .defaultScreenshot
            case .commandShiftFive: HotKeyDefinition(keyCode: 23, key: "5", command: true, shift: true)
            case .controlShiftFive: .legacyScreenshot
            }
        }
    }
}

public enum ScreenshotPolicy {
    public static func resolvedMode(settings: ScreenshotSettings, requestedMode: ScreenshotMode?) -> ScreenshotMode {
        requestedMode ?? settings.mode
    }

    public static func settingsAfterCapture(_ settings: ScreenshotSettings, usedMode: ScreenshotMode) -> ScreenshotSettings {
        guard settings.remembersLastMode else { return settings }
        var updated = settings
        updated.mode = usedMode
        return updated
    }
}
