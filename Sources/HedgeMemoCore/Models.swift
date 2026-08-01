import Foundation

/// Case-insensitive fuzzy matching with `%` as an ordered-fragment wildcard.
/// Queries are implicitly fuzzy on both ends, so `jav%` can match text that has
/// characters before `jav`; `%` is useful for requiring separated fragments
/// such as `java%script`. Queries without `%` retain contains behavior.
public struct PercentFuzzyMatcher: Sendable {
    private let pattern: String
    private let fragments: [String]
    private let hasWildcard: Bool
    /// Empty queries and patterns made only from `%` accept every candidate.
    /// Exposing this lets collection filters skip candidate-string preparation
    /// entirely — important for blank searches over a large clipboard history.
    public let matchesEveryCandidate: Bool
    /// Canonical form used by presentation caches. Queries differing only in
    /// surrounding whitespace have identical matching semantics.
    public var cacheKey: String { pattern }

    public init(query: String) {
        pattern = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasWildcard = pattern.contains("%")
        fragments = hasWildcard
            ? pattern.split(separator: "%").map(String.init)
            : []
        matchesEveryCandidate = pattern.isEmpty || (hasWildcard && fragments.isEmpty)
    }

    public func matches(_ candidate: String) -> Bool {
        guard !matchesEveryCandidate else { return true }
        guard hasWildcard else { return candidate.localizedCaseInsensitiveContains(pattern) }

        let options: String.CompareOptions = [.caseInsensitive]
        var cursor = candidate.startIndex

        for fragment in fragments {
            guard let match = candidate.range(of: fragment, options: options, range: cursor..<candidate.endIndex) else {
                return false
            }
            cursor = match.upperBound
        }
        return true
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

/// Stores the SHA-256 values produced by HedgeMemo as four inline machine
/// words instead of one separately allocated 64-character String per record.
///
/// Legacy snapshots and tests may contain arbitrary identifiers in the hash
/// field, so non-canonical values retain their exact String representation.
/// Codable models still encode/decode the public string form unchanged.
struct CompactContentHash: Hashable, Sendable {
    private enum Storage: Hashable, Sendable {
        case sha256(UInt64, UInt64, UInt64, UInt64)
        case verbatim(String)
    }

    private let storage: Storage

    init(_ value: String) {
        guard value.utf8.count == 64 else {
            storage = .verbatim(value)
            return
        }
        var words = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        for (index, byte) in value.utf8.enumerated() {
            let nibble: UInt64
            switch byte {
            case 48...57: nibble = UInt64(byte - 48)
            case 97...102: nibble = UInt64(byte - 87)
            default:
                storage = .verbatim(value)
                return
            }
            switch index / 16 {
            case 0: words.0 = (words.0 << 4) | nibble
            case 1: words.1 = (words.1 << 4) | nibble
            case 2: words.2 = (words.2 << 4) | nibble
            default: words.3 = (words.3 << 4) | nibble
            }
        }
        storage = .sha256(words.0, words.1, words.2, words.3)
    }

    var stringValue: String {
        switch storage {
        case .verbatim(let value):
            return value
        case .sha256(let first, let second, let third, let fourth):
            var bytes: [UInt8] = []
            bytes.reserveCapacity(64)
            Self.appendHexBytes(of: first, to: &bytes)
            Self.appendHexBytes(of: second, to: &bytes)
            Self.appendHexBytes(of: third, to: &bytes)
            Self.appendHexBytes(of: fourth, to: &bytes)
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Exact binary key for the disposable archive-import index. Canonical
    /// SHA-256 values stay as their 32 raw bytes instead of being rebuilt into
    /// a 64-byte UTF-8 string; a storage tag keeps arbitrary legacy strings
    /// collision-free, and the first byte preserves secret/non-secret identity.
    func archiveDedupKey(isSecret: Bool) -> Data {
        var key = Data()
        switch storage {
        case .sha256(let first, let second, let third, let fourth):
            key.reserveCapacity(34)
            key.append(isSecret ? 1 : 0)
            key.append(0)
            Self.appendBigEndian(first, to: &key)
            Self.appendBigEndian(second, to: &key)
            Self.appendBigEndian(third, to: &key)
            Self.appendBigEndian(fourth, to: &key)
        case .verbatim(let value):
            key.reserveCapacity(2 + value.utf8.count)
            key.append(isSecret ? 1 : 0)
            key.append(1)
            key.append(contentsOf: value.utf8)
        }
        return key
    }

    private static func appendBigEndian(
        _ value: UInt64,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendHexBytes(
        of word: UInt64,
        to bytes: inout [UInt8]
    ) {
        for shift in stride(from: 60, through: 0, by: -4) {
            let nibble = UInt8((word >> UInt64(shift)) & 0xF)
            bytes.append(nibble < 10 ? 48 + nibble : 87 + nibble)
        }
    }

    var usesInlineSHA256Storage: Bool {
        if case .sha256 = storage { return true }
        return false
    }

    static var storageStride: Int { MemoryLayout<Self>.stride }
}

struct MemeTextBody: Sendable {
    let note: String
    let ocrText: String
}

private final class MemeTextBox: Sendable {
    let body: MemeTextBody

    init(note: String, ocrText: String) {
        body = MemeTextBody(note: note, ocrText: ocrText)
    }

    init(_ body: MemeTextBody) {
        self.body = body
    }
}

final class MemeTextProvider: @unchecked Sendable {
    private let cache = NSCache<NSUUID, MemeTextBox>()
    private let loader: @Sendable (UUID) -> MemeTextBody?

    init(loader: @escaping @Sendable (UUID) -> MemeTextBody?) {
        self.loader = loader
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func body(for id: UUID) -> MemeTextBody {
        let key = id as NSUUID
        if let cached = cache.object(forKey: key) { return cached.body }
        let body = loader(id) ?? MemeTextBody(note: "", ocrText: "")
        cache.setObject(
            MemeTextBox(body),
            forKey: key,
            cost: max(1, body.note.utf8.count + body.ocrText.utf8.count)
        )
        return body
    }

    /// Reuses a body already loaded for the UI, but does not let a cold
    /// database snapshot fill the bounded display cache with every row it
    /// serializes.
    func bodyForPersistence(for id: UUID) -> MemeTextBody {
        let key = id as NSUUID
        if let cached = cache.object(forKey: key) { return cached.body }
        return loader(id) ?? MemeTextBody(note: "", ocrText: "")
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private enum MemeTextState: Sendable {
    case resident(MemeTextBox)
    case deferred(MemeTextProvider)
    case metadata
}

public struct MemeItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var fileName: String
    var compactContentHash: CompactContentHash
    public var contentHash: String {
        get { compactContentHash.stringValue }
        set { compactContentHash = CompactContentHash(newValue) }
    }
    private var textState: MemeTextState
    public var note: String {
        get {
            switch textState {
            case .resident(let box): box.body.note
            case .deferred(let provider): provider.body(for: id).note
            case .metadata: ""
            }
        }
        set {
            let currentOCR = ocrText
            textState = .resident(
                MemeTextBox(note: newValue, ocrText: currentOCR)
            )
            updatedAt = .now
        }
    }
    public var ocrText: String {
        get {
            switch textState {
            case .resident(let box): box.body.ocrText
            case .deferred(let provider): provider.body(for: id).ocrText
            case .metadata: ""
            }
        }
        set {
            let currentNote = note
            textState = .resident(
                MemeTextBox(note: currentNote, ocrText: newValue)
            )
            updatedAt = .now
        }
    }
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
        self.compactContentHash = CompactContentHash(contentHash)
        self.textState = .resident(
            MemeTextBox(note: note, ocrText: ocrText)
        )
        self.categoryID = categoryID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, contentHash, note, ocrText, categoryID
        case sortOrder, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        compactContentHash = CompactContentHash(
            try container.decode(String.self, forKey: .contentHash)
        )
        textState = .resident(
            MemeTextBox(
                note: try container.decodeIfPresent(
                    String.self,
                    forKey: .note
                ) ?? "",
                ocrText: try container.decodeIfPresent(
                    String.self,
                    forKey: .ocrText
                ) ?? ""
            )
        )
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(note, forKey: .note)
        try container.encode(ocrText, forKey: .ocrText)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public static func == (lhs: MemeItem, rhs: MemeItem) -> Bool {
        lhs.id == rhs.id
            && lhs.fileName == rhs.fileName
            && lhs.compactContentHash == rhs.compactContentHash
            && lhs.categoryID == rhs.categoryID
            && lhs.sortOrder == rhs.sortOrder
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fileName)
        hasher.combine(compactContentHash)
        hasher.combine(categoryID)
        hasher.combine(sortOrder)
        hasher.combine(createdAt)
        hasher.combine(updatedAt)
    }

    mutating func deferText(to provider: MemeTextProvider) {
        textState = .deferred(provider)
    }

    var metadataProjection: MemeItem {
        var projection = self
        projection.textState = .metadata
        return projection
    }

    var requiresDeferredTextRead: Bool {
        if case .deferred = textState { return true }
        return false
    }

    /// Resolves both deferred text columns once while keeping cold snapshot
    /// writes out of the display cache. The resident projection also prevents
    /// Codable from asking the provider again for note and OCR separately.
    var persistenceProjection: (meme: MemeItem, body: MemeTextBody) {
        let body: MemeTextBody
        switch textState {
        case .resident(let box):
            body = box.body
        case .deferred(let provider):
            body = provider.bodyForPersistence(for: id)
        case .metadata:
            body = MemeTextBody(note: "", ocrText: "")
        }
        var projection = self
        projection.textState = .resident(MemeTextBox(body))
        return (projection, body)
    }

    var decodedStoredTextByteCount: Int {
        guard case .resident(let box) = textState else { return 0 }
        return box.body.note.utf8.count + box.body.ocrText.utf8.count
    }

    static var storageStride: Int { MemoryLayout<Self>.stride }
    static var textStateStorageStride: Int {
        MemoryLayout<MemeTextState>.stride
    }

    public func matches(query: String) -> Bool {
        matches(matcher: PercentFuzzyMatcher(query: query))
    }

    public func matches(matcher: PercentFuzzyMatcher) -> Bool {
        matcher.matches(note) || matcher.matches(ocrText)
    }
}

#if DEBUG
/// Pre-1.2.25 stored-field shape for an in-module stride comparison. This type
/// is excluded from release builds.
private struct LegacyMemeItemLayout {
    let id: UUID
    var fileName: String
    var compactContentHash: CompactContentHash
    var storedNote: String
    var storedOCRText: String
    var deferredTextProvider: MemeTextProvider?
    var categoryID: UUID?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

extension MemeItem {
    static var legacyStorageStrideForTesting: Int {
        MemoryLayout<LegacyMemeItemLayout>.stride
    }
}
#endif

public struct MemeSnapshot: Codable, Sendable {
    public var categories: [MemeCategory]
    public var memes: [MemeItem]

    public init(categories: [MemeCategory] = [], memes: [MemeItem] = []) {
        self.categories = categories
        self.memes = memes
    }
}

/// Stable keyset cursor for loading a large meme library without retaining the
/// complete result set. It follows the same ordering as `MemeFilter`.
public struct MemePageCursor: Equatable, Sendable {
    let sortOrder: Int
    let createdAt: TimeInterval
    let id: String

    init(sortOrder: Int, createdAt: TimeInterval, id: String) {
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.id = id
    }
}

public struct MemePage: Sendable {
    public let items: [MemeItem]
    public let nextCursor: MemePageCursor?

    public init(items: [MemeItem], nextCursor: MemePageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum MemeFilter {
    public static func apply(_ memes: [MemeItem], categoryID: UUID?, query: String) -> [MemeItem] {
        let matcher = PercentFuzzyMatcher(query: query)
        var result: [MemeItem] = []
        result.reserveCapacity(memes.count)
        for meme in memes {
            guard categoryID == nil || meme.categoryID == categoryID,
                  matcher.matchesEveryCandidate || meme.matches(matcher: matcher) else {
                continue
            }
            result.append(meme)
        }
        result.sort { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder { return lhs.createdAt < rhs.createdAt }
            return lhs.sortOrder < rhs.sortOrder
        }
        return result
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
    case password

    public var displayName: String {
        switch self {
        case .text: L10n.text("文本")
        case .code: L10n.text("代码")
        case .link: L10n.text("链接")
        case .image: L10n.text("图片")
        case .screenshot: L10n.text("截图")
        case .password: L10n.text("密码")
        }
    }

    public var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .image: "photo"
        case .screenshot: "camera.viewfinder"
        case .password: "key.fill"
        }
    }
}

/// The source is optional so snapshots written before screenshot separation
/// continue to decode as ordinary image entries.
public enum ClipboardEntryOrigin: String, Codable, Sendable {
    // The raw value is persisted in the clipboard database and ZIP manifests;
    // it keeps the pre-rename (MemeMemo era) spelling so existing snapshots
    // and archives continue to decode after the HedgeMemo rename.
    case hedgeMemoScreenshot = "memeMemoScreenshot"
    /// Copied from a source that marked the pasteboard concealed (password
    /// managers, browser password fields). Category comes from this marker
    /// rather than from the text, because a strong password is
    /// indistinguishable from random text by inspection.
    case concealedPassword
}

public enum ClipboardRuleMatchMode: String, Codable, CaseIterable, Sendable {
    case all
    case any

    public var displayName: String {
        switch self {
        case .all: L10n.text("满足全部条件")
        case .any: L10n.text("满足任一条件")
        }
    }
}

public enum ClipboardClassificationRuleKind: String, Codable, CaseIterable, Sendable {
    case contains
    case startsWith
    case endsWith
    case regularExpression
    case sourceApplication
    case contentType

    public var displayName: String {
        switch self {
        case .contains: L10n.text("内容包含")
        case .startsWith: L10n.text("内容开头是")
        case .endsWith: L10n.text("内容结尾是")
        case .regularExpression: L10n.text("正则表达式")
        case .sourceApplication: L10n.text("来源应用")
        case .contentType: L10n.text("内容类型")
        }
    }
}

public struct ClipboardClassificationRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var kind: ClipboardClassificationRuleKind
    public var value: String
    public var displayValue: String?
    public var isNegated: Bool
    public var isCaseSensitive: Bool

    public init(
        id: UUID = UUID(),
        kind: ClipboardClassificationRuleKind,
        value: String = "",
        displayValue: String? = nil,
        isNegated: Bool = false,
        isCaseSensitive: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.displayValue = displayValue
        self.isNegated = isNegated
        self.isCaseSensitive = isCaseSensitive
    }

    public func validate() throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ClipboardClassificationRuleError.missingValue(kind)
        }
        switch kind {
        case .regularExpression:
            guard CustomClipboardCategory.compiledRegex(
                for: value,
                caseSensitive: isCaseSensitive
            ) != nil else {
                throw ClipboardClassificationRuleError.invalidRegularExpression(value)
            }
        case .contentType:
            guard let category = ClipboardContentCategory(rawValue: value),
                  category != .password else {
                throw ClipboardClassificationRuleError.invalidContentType(value)
            }
        default:
            break
        }
    }

    fileprivate func matches(_ entry: ClipboardEntry) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let rawResult: Bool
        switch kind {
        case .contains, .startsWith, .endsWith:
            guard entry.kind == .text, !entry.isSecret, let text = entry.text else {
                rawResult = false
                break
            }
            let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
            switch kind {
            case .contains:
                rawResult = text.range(of: value, options: options) != nil
            case .startsWith:
                rawResult = text.range(
                    of: value,
                    options: options.union(.anchored),
                    range: text.startIndex..<text.endIndex
                ) != nil
            case .endsWith:
                rawResult = text.range(
                    of: value,
                    options: options.union([.anchored, .backwards]),
                    range: text.startIndex..<text.endIndex
                ) != nil
            default:
                rawResult = false
            }
        case .regularExpression:
            guard entry.kind == .text, !entry.isSecret, let text = entry.text,
                  let regex = CustomClipboardCategory.compiledRegex(
                    for: value,
                    caseSensitive: isCaseSensitive
                  ) else {
                rawResult = false
                break
            }
            let scanned = text.count > CustomClipboardCategory.maxMatchLength
                ? String(text.prefix(CustomClipboardCategory.maxMatchLength))
                : text
            rawResult = regex.firstMatch(
                in: scanned,
                range: NSRange(scanned.startIndex..., in: scanned)
            ) != nil
        case .sourceApplication:
            guard let source = entry.sourceApplication else {
                rawResult = false
                break
            }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            rawResult = source.stableIdentifier.caseInsensitiveCompare(cleaned) == .orderedSame
                || source.bundleIdentifier?.caseInsensitiveCompare(cleaned) == .orderedSame
                || source.displayName.localizedCaseInsensitiveContains(cleaned)
        case .contentType:
            rawResult = entry.contentCategory.rawValue == value
        }
        return isNegated ? !rawResult : rawResult
    }
}

public enum ClipboardClassificationRuleError: LocalizedError, Equatable {
    case noRules
    case tooManyRules(Int)
    case missingValue(ClipboardClassificationRuleKind)
    case invalidRegularExpression(String)
    case invalidContentType(String)

    public var errorDescription: String? {
        switch self {
        case .noRules:
            L10n.text("请至少添加一条分类条件。")
        case .tooManyRules:
            L10n.text("每个分类最多可以添加八条条件。")
        case .missingValue:
            L10n.text("分类条件不能为空。")
        case .invalidRegularExpression:
            L10n.text("正则表达式无效")
        case .invalidContentType:
            L10n.text("分类条件中的内容类型无效。")
        }
    }
}

/// User-defined category. Legacy `pattern` remains persisted so existing
/// regex-only categories decode without migration work; new categories use
/// composable rules.
public struct CustomClipboardCategory: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var pattern: String
    public var matchMode: ClipboardRuleMatchMode?
    public var rules: [ClipboardClassificationRule]?

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        matchMode: ClipboardRuleMatchMode? = nil,
        rules: [ClipboardClassificationRule]? = nil
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.matchMode = matchMode
        self.rules = rules
    }

    public init(
        id: UUID = UUID(),
        name: String,
        matchMode: ClipboardRuleMatchMode = .all,
        rules: [ClipboardClassificationRule]
    ) {
        self.id = id
        self.name = name
        self.pattern = ""
        self.matchMode = matchMode
        self.rules = rules
    }

    public var resolvedMatchMode: ClipboardRuleMatchMode { matchMode ?? .all }

    public var effectiveRules: [ClipboardClassificationRule] {
        if let rules, !rules.isEmpty { return rules }
        guard !pattern.isEmpty else { return [] }
        return [
            ClipboardClassificationRule(
                kind: .regularExpression,
                value: pattern,
                isCaseSensitive: true
            )
        ]
    }

    public var isPatternValid: Bool {
        !pattern.isEmpty && Self.compiledRegex(for: pattern, caseSensitive: true) != nil
    }

    public var isRuleSetValid: Bool {
        (try? validate()) != nil
    }

    public func validate() throws {
        let rules = effectiveRules
        guard !rules.isEmpty else { throw ClipboardClassificationRuleError.noRules }
        guard rules.count <= 8 else {
            throw ClipboardClassificationRuleError.tooManyRules(rules.count)
        }
        for rule in rules { try rule.validate() }
    }

    public func matches(_ text: String) -> Bool {
        matches(
            ClipboardEntry(
                kind: .text,
                text: text,
                contentHash: Data(text.utf8).clipboardContentHash
            )
        )
    }

    public func matches(_ entry: ClipboardEntry) -> Bool {
        // Secrets remain exclusive to the password category and its mandatory
        // lock. A broad source/content rule must never surface one in an
        // ordinary custom category.
        guard !entry.isSecret else { return false }
        let rules = effectiveRules
        guard !rules.isEmpty, rules.count <= 8 else { return false }
        switch resolvedMatchMode {
        case .all: return rules.allSatisfy { $0.matches(entry) }
        case .any: return rules.contains { $0.matches(entry) }
        }
    }

    fileprivate static let maxMatchLength = 10_000

    /// Compiling an `NSRegularExpression` is not free, and the old code rebuilt
    /// one on every `matches`/`isPatternValid` call — i.e. once per entry per
    /// filter pass. Cache by pattern string so each distinct pattern compiles
    /// once. NSCache is thread-safe.
    nonisolated(unsafe) private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        // A user can edit category rules repeatedly for the entire lifetime of
        // the menu-bar process. Keep the useful working set, but do not retain
        // every historical pattern forever.
        cache.countLimit = 128
        return cache
    }()

    fileprivate static func releaseRegexCache() {
        regexCache.removeAllObjects()
    }

    fileprivate static func compiledRegex(
        for pattern: String,
        caseSensitive: Bool
    ) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let key = "\(caseSensitive ? "1" : "0"):\(pattern)" as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }
}

/// Identifies either a built-in category or a custom rule category,
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
        isLink(trimmed: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// For callers that have already trimmed. Trimming copies the whole string,
    /// and the code detector consults this on text it has just trimmed itself.
    static func isLink(trimmed text: String) -> Bool {
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
        // The passes below each used to re-split the text into lines, re-lower
        // it and re-measure its symbol density. Deriving those once is what
        // makes classifying a large history affordable; the heuristics
        // themselves are unchanged.
        let lines = text.components(separatedBy: .newlines)
        // A technical work log, README or issue description can contain many
        // identifiers, parentheses and even short statements without itself
        // being source code. Judge long multi-line input by line composition
        // before allowing one embedded snippet to dominate the whole paste.
        if looksLikeLongFormDocument(text, lines: lines) { return false }
        let lowered = text.lowercased()
        let symbols = symbolRatio(text)
        let prose = looksLikeProse(lowered: lowered)
        let structureStrength = hardStructureStrength(text, lines: lines, symbolRatio: symbols)
        if prose, structureStrength < 2 { return false }
        // Unambiguous structure (braces, terminators, comments, operators, high
        // symbol density) is code regardless of any incidental English words.
        if structureStrength > 0 {
            return score(text, lowered: lowered, lines: lines, symbolRatio: symbols) >= 3
        }
        // Without that structure, a keyword or a stray parenthesis is not enough
        // on its own: long English prose borrows words like "return", "public"
        // and "where". If the text reads as sentences, treat it as prose.
        if prose { return false }
        return score(text, lowered: lowered, lines: lines, symbolRatio: symbols) >= 3
    }

    /// Long natural-language documents often discuss code and quote a few code
    /// fragments. Similar clipboard managers bias ambiguous mixed content toward
    /// text because that avoids applying syntax color to an entire email/README;
    /// only a code-dominant line mix crosses back into the code bucket.
    private static func looksLikeLongFormDocument(_ text: String, lines rawLines: [String]) -> Bool {
        guard text.count >= 240 else { return false }
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 6 else { return false }

        var proseLines = 0
        var codeLines = 0
        var documentMarkers = 0
        var insideFence = false

        for line in lines {
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideFence.toggle()
                documentMarkers += 1
                continue
            }
            if insideFence {
                codeLines += 1
                continue
            }
            if isDocumentMarker(line) { documentMarkers += 1 }
            if isStrongCodeLine(line) { codeLines += 1 }
            else if isNaturalLanguageLine(line) { proseLines += 1 }
        }

        guard proseLines >= 4 else { return false }
        if documentMarkers >= 2, proseLines >= codeLines { return true }
        return proseLines >= codeLines * 2 + 2
    }

    private static func isDocumentMarker(_ line: String) -> Bool {
        if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") { return true }
        return line.range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) != nil
    }

    private static func isNaturalLanguageLine(_ rawLine: String) -> Bool {
        let line = rawLine.replacingOccurrences(
            of: "^(#{1,6}|[-*>]|[0-9]+[.)])\\s+",
            with: "",
            options: .regularExpression
        )
        if line.count >= 12, cjkRatio(line) > 0.2 { return true }
        let words = line.lowercased().split { !$0.isLetter }.map(String.init)
        guard words.count >= 5 else { return false }
        let functionWordCount = words.reduce(into: 0) { count, word in
            if proseWords.contains(word) { count += 1 }
        }
        return functionWordCount >= 2
            || line.hasSuffix(".")
            || line.hasSuffix("?")
            || line.hasSuffix("!")
            || line.hasSuffix("。")
    }

    /// Deliberately stricter than the final score: this decides whether a line
    /// in a mixed document is source, so API names in prose do not count.
    private static func isStrongCodeLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("#!") { return true }
        if line.hasSuffix(";") || line.hasSuffix("{") || line.hasSuffix("}") || line.hasSuffix("):") { return true }
        if operators.contains(where: { line.contains($0) }) { return true }
        if line.range(of: "^[A-Za-z_$][A-Za-z0-9_.$\\[\\]-]*\\s*[:+*/%&|?-]?=", options: .regularExpression) != nil {
            return true
        }
        if line.range(of: "^\"[^\"]+\"\\s*:\\s*", options: .regularExpression) != nil { return true }
        return keywords.contains(where: { lowered.hasPrefix($0) })
    }

    /// Whether the text reads as natural-language prose rather than code.
    /// English is dense with common function words ("the", "is", "to", …) that
    /// code almost never uses; several distinct ones, or a high proportion of
    /// them across a longer run, is a decisive prose signal.
    private static func looksLikeProse(lowered: String) -> Bool {
        let words = lowered.split { !$0.isLetter }.map(String.init)
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
    private static func hardStructureStrength(
        _ text: String,
        lines: [String],
        symbolRatio symbols: Double
    ) -> Int {
        var strength = 0
        if lines.contains(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed.hasSuffix("):")
        }) { strength += 1 }
        if operators.contains(where: { text.contains($0) }) { strength += 1 }
        if text.contains("//") || text.contains("/*") || text.contains("*/") || text.contains("#!") { strength += 1 }
        if text.contains("{") && text.contains("}") { strength += 1 }
        if lines.contains(where: isStrongCodeLine) { strength += 1 }
        if symbols > 0.15 { strength += 1 }
        return strength
    }

    private static func score(
        _ text: String,
        lowered: String,
        lines: [String],
        symbolRatio symbols: Double
    ) -> Int {
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
        if symbols > 0.08 { score += 1 }
        return score
    }

    private static func isLikelyLink(_ text: String) -> Bool {
        ClipboardLinkDetector.isLink(trimmed: text)
    }

    // Hoisted out of the ratio helpers below. Both previously built a
    // `CharacterSet` (one of them from a string literal) on every call, i.e.
    // once per entry per classification.
    private static let alphanumerics = CharacterSet.alphanumerics
    private static let whitespacesAndNewlines = CharacterSet.whitespacesAndNewlines
    private static let symbolCharacters = CharacterSet(charactersIn: "{}()[];<>=+*/%&|!$#@\\_")

    /// Counted in one pass. The previous form materialized an array of every
    /// matching scalar, then a second array of the CJK subset.
    private static func cjkRatio(_ text: String) -> Double {
        var letters = 0
        var cjk = 0
        for scalar in text.unicodeScalars where alphanumerics.contains(scalar) {
            letters += 1
            if (0x4E00...0x9FFF).contains(Int(scalar.value)) { cjk += 1 }
        }
        guard letters > 0 else { return 0 }
        return Double(cjk) / Double(letters)
    }

    private static func symbolRatio(_ text: String) -> Double {
        var meaningful = 0
        var hits = 0
        for scalar in text.unicodeScalars where !whitespacesAndNewlines.contains(scalar) {
            meaningful += 1
            if symbolCharacters.contains(scalar) { hits += 1 }
        }
        guard meaningful > 0 else { return 0 }
        return Double(hits) / Double(meaningful)
    }
}

/// Memoizes the link/code classification of a text entry.
///
/// Detection scans the whole text several times, and the category is consulted
/// constantly: every list filter asks every entry for it, so a 10,000-item
/// history re-derives it thousands of times per panel open. The key is the
/// content hash — it always tracks the text, since edits recompute it — plus
/// the byte length, which guards against a reused hand-written hash across
/// differently sized texts.
///
/// A plain dictionary behind a lock replaces the previous `NSCache`: the cache
/// key had to be interpolated into a fresh `NSString` on every single lookup,
/// which allocated once per entry per filter pass and dominated the classifier
/// itself once the results were warm. The capacity comfortably exceeds the
/// largest history the app will keep (10,000 entries), and the whole table is
/// dropped rather than evicted one by one when it is exceeded — a full reload
/// costs one classification pass, while per-item eviction would keep a large
/// history permanently thrashing.
final class TextCategoryCache: @unchecked Sendable {
    static let shared = TextCategoryCache()

    /// A composite key rather than a hash key validated against the length:
    /// with a single slot per hash, two texts that share one would evict each
    /// other on every lookup and never be cached at all.
    private struct Key: Hashable { let contentHash: String; let byteCount: Int }

    private let lock = NSLock()
    private var storage: [Key: ClipboardContentCategory] = [:]
    private static let capacity = 12_000

    func category(contentHash: String, text: String) -> ClipboardContentCategory {
        let key = Key(contentHash: contentHash, byteCount: text.utf8.count)
        lock.lock()
        let cached = storage[key]
        lock.unlock()
        if let cached { return cached }

        let category: ClipboardContentCategory
        if ClipboardLinkDetector.isLink(text) {
            category = .link
        } else if ClipboardCodeDetector.isCode(text) {
            category = .code
        } else {
            category = .text
        }

        lock.lock()
        if storage.count >= Self.capacity { storage.removeAll(keepingCapacity: true) }
        storage[key] = category
        lock.unlock()
        return category
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

/// Process-lifetime classification helpers are presentation accelerators, not
/// user data. The app calls this on memory pressure and when moving into a long
/// background interval; the next lookup deterministically rebuilds the exact
/// same result.
public enum ClipboardRuntimeCaches {
    public static func removeAll() {
        CustomClipboardCategory.releaseRegexCache()
        TextCategoryCache.shared.removeAll()
    }
}

public enum ClipboardItemSize: String, Codable, CaseIterable, Sendable {
    case compact
    case regular
    case large

    public var displayName: String {
        switch self {
        case .compact: L10n.text("紧凑")
        case .regular: L10n.text("标准")
        case .large: L10n.text("大")
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
    /// The meme panel is a quick picker, so its default stays adjacent to the
    /// other Command-Shift shortcuts without overlapping them.
    public static let defaultMemePanel = HotKeyDefinition(keyCode: 14, key: "E", command: true, shift: true)
    public static let legacyScreenshot = HotKeyDefinition(keyCode: 23, key: "5", control: true, shift: true)

    /// A global hot key needs at least one of Command/Option/Control. Shift
    /// alone is rejected: a Shift-only global shortcut would fire while the user
    /// is simply typing capital letters.
    public var isUsable: Bool {
        keyCode > 0 && !key.isEmpty && (command || option || control)
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
        guard let hotKey, hotKey.isUsable else { return L10n.text("未设置") }
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
        case .system: L10n.text("系统彩色")
        case .xcodeLight: L10n.text("Xcode 浅色")
        case .solarizedLight: L10n.text("Solarized 浅色")
        case .githubLight: L10n.text("GitHub 浅色")
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .system: L10n.text("使用 macOS 自适应的蓝绿紫语法颜色")
        case .xcodeLight: L10n.text("使用接近 Xcode 的高对比浅色配色")
        case .solarizedLight: L10n.text("使用低对比、护眼的 Solarized 浅色配色")
        case .githubLight: L10n.text("使用 GitHub 风格的清晰浅色配色")
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
    /// Optional fields preserve snapshots written before per-application
    /// capture policy existed.
    public var appFilterMode: ClipboardAppFilterMode?
    public var appFilterApplications: [ClipboardSourceApplication]?
    /// Optional fields preserve settings written before the panel's advanced
    /// filter and sort controls existed.
    public var advancedModeEnabled: Bool?
    public var advancedSourceIdentifier: String?
    public var advancedSortField: ClipboardAdvancedSortField?
    public var advancedSortDirection: ClipboardSortDirection?
    /// FIFO paste queue entry identifiers. Keeping identifiers instead of
    /// duplicating payloads preserves rich text, images, and encrypted secrets
    /// through the same single source of truth as ordinary history.
    public var pasteQueueEntryIDs: [UUID]?

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
        codeHighlightTheme: CodeHighlightTheme? = .system,
        appFilterMode: ClipboardAppFilterMode? = .disabled,
        appFilterApplications: [ClipboardSourceApplication]? = nil,
        advancedModeEnabled: Bool? = false,
        advancedSourceIdentifier: String? = nil,
        advancedSortField: ClipboardAdvancedSortField? = .capturedAt,
        advancedSortDirection: ClipboardSortDirection? = .descending,
        pasteQueueEntryIDs: [UUID]? = nil
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
        self.appFilterMode = appFilterMode
        self.appFilterApplications = appFilterApplications
        self.advancedModeEnabled = advancedModeEnabled
        self.advancedSourceIdentifier = advancedSourceIdentifier
        self.advancedSortField = advancedSortField
        self.advancedSortDirection = advancedSortDirection
        self.pasteQueueEntryIDs = pasteQueueEntryIDs
        normalize()
    }

    public var resolvedCodeHighlightTheme: CodeHighlightTheme {
        codeHighlightTheme ?? .system
    }

    public var resolvedAppFilterMode: ClipboardAppFilterMode {
        appFilterMode ?? .disabled
    }

    public var resolvedAdvancedModeEnabled: Bool { advancedModeEnabled ?? false }
    public var resolvedAdvancedSortField: ClipboardAdvancedSortField {
        advancedSortField ?? .capturedAt
    }
    public var resolvedAdvancedSortDirection: ClipboardSortDirection {
        advancedSortDirection ?? .descending
    }
    public var resolvedPasteQueueEntryIDs: [UUID] { pasteQueueEntryIDs ?? [] }
    public var resolvedAdvancedOptions: ClipboardAdvancedOptions? {
        guard resolvedAdvancedModeEnabled else { return nil }
        return ClipboardAdvancedOptions(
            sourceIdentifier: advancedSourceIdentifier,
            sortField: resolvedAdvancedSortField,
            sortDirection: resolvedAdvancedSortDirection
        )
    }

    public func allowsCapture(from source: ClipboardSourceApplication?) -> Bool {
        ClipboardAppCapturePolicy.allows(
            source: source,
            mode: resolvedAppFilterMode,
            applications: appFilterApplications ?? []
        )
    }

    /// Choosing a new sort field starts in natural ascending order. Choosing
    /// the currently active field again reverses it, keeping direction inside
    /// the native field Picker instead of requiring a separate control.
    public mutating func selectAdvancedSortField(_ field: ClipboardAdvancedSortField) {
        if resolvedAdvancedSortField == field {
            advancedSortDirection =
                resolvedAdvancedSortDirection == .ascending
                ? .descending
                : .ascending
        } else {
            advancedSortField = field
            advancedSortDirection = .ascending
        }
    }

    public mutating func addAppFilterApplication(_ application: ClipboardSourceApplication) {
        var applications = appFilterApplications ?? []
        guard !applications.contains(where: { $0.matches(application) }) else { return }
        applications.append(application)
        appFilterApplications = applications
    }

    public mutating func removeAppFilterApplication(id: String) {
        appFilterApplications?.removeAll { $0.stableIdentifier == id }
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

    public func validateCustomCategories() throws {
        for category in customCategories ?? [] {
            try category.validate()
        }
    }

    public mutating func normalize() {
        maxEntries = Self.normalizedMaxEntries(maxEntries)
        if hotKey == nil || hotKey == .legacyClipboard { hotKey = .defaultClipboard }
        let customs = customCategories ?? []
        customCategories = customs
        appFilterMode = resolvedAppFilterMode
        advancedModeEnabled = resolvedAdvancedModeEnabled
        advancedSortField = resolvedAdvancedSortField
        advancedSortDirection = resolvedAdvancedSortDirection
        var seenQueueIDs = Set<UUID>()
        pasteQueueEntryIDs = resolvedPasteQueueEntryIDs.filter {
            seenQueueIDs.insert($0).inserted
        }
        if advancedSourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            advancedSourceIdentifier = nil
        }
        var seenApplications = Set<String>()
        appFilterApplications = (appFilterApplications ?? []).filter {
            !$0.displayName.isEmpty && seenApplications.insert($0.stableIdentifier).inserted
        }

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

private final class ClipboardTextBox: Sendable {
    let value: String?
    init(_ value: String?) { self.value = value }
}

final class ClipboardEntryTextProvider: @unchecked Sendable {
    private let cache = NSCache<NSUUID, ClipboardTextBox>()
    private let sourceLock = NSLock()
    private var loader: (@Sendable (UUID) -> String?)?
    private var redirectedProvider: ClipboardEntryTextProvider?
    private let cachesValues: Bool

    init(
        cachesValues: Bool = true,
        loader: @escaping @Sendable (UUID) -> String?
    ) {
        self.loader = loader
        self.cachesValues = cachesValues
        cache.countLimit = 512
        cache.totalCostLimit = 12 * 1024 * 1024
    }

    func text(for id: UUID) -> String? {
        let source = sourceLock.withLock {
            (
                loader: loader,
                redirectedProvider: redirectedProvider
            )
        }
        if let redirectedProvider = source.redirectedProvider {
            return redirectedProvider.text(for: id)
        }
        guard let loader = source.loader else { return nil }
        guard cachesValues else { return loader(id) }
        let key = id as NSUUID
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = loader(id)
        cache.setObject(
            ClipboardTextBox(value),
            forKey: key,
            cost: max(1, value?.utf8.count ?? 1)
        )
        return value
    }

    /// Reuses a value already loaded for the UI, but does not let a cold
    /// database snapshot fill the display cache with every body it writes.
    func textForPersistence(for id: UUID) -> String? {
        let source = sourceLock.withLock {
            (
                loader: loader,
                redirectedProvider: redirectedProvider
            )
        }
        if let redirectedProvider = source.redirectedProvider {
            return redirectedProvider.textForPersistence(for: id)
        }
        guard let loader = source.loader else { return nil }
        let key = id as NSUUID
        if let cached = cache.object(forKey: key) { return cached.value }
        return loader(id)
    }

    /// Imported text initially resolves through a disposable SQLite staging
    /// file. Once the canonical snapshot is durable, release that loader and
    /// forward the same lightweight model references to the repository
    /// provider. No observable entry-array mutation is needed.
    func redirect(to provider: ClipboardEntryTextProvider) {
        guard self !== provider else { return }
        sourceLock.withLock {
            loader = nil
            redirectedProvider = provider
        }
        cache.removeAllObjects()
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private enum ClipboardTextState: Sendable {
    case resident(ClipboardTextBox)
    case deferred(ClipboardEntryTextProvider)
    case metadata
}

/// Immutable source metadata can be shared by every entry captured from the
/// same application. Keeping all three strings behind one reference removes
/// two stored reference slots from every `ClipboardEntry`; mutations create a
/// replacement box so the public struct retains value semantics.
final class ClipboardSourceMetadataBox: Hashable, Sendable {
    let displayName: String?
    let bundleIdentifier: String?
    let bundleURLPath: String?

    init(
        displayName: String?,
        bundleIdentifier: String?,
        bundleURLPath: String?
    ) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundleURLPath = bundleURLPath
    }

    static func make(
        displayName: String?,
        bundleIdentifier: String?,
        bundleURLPath: String?
    ) -> ClipboardSourceMetadataBox? {
        guard displayName != nil || bundleIdentifier != nil || bundleURLPath != nil else {
            return nil
        }
        return ClipboardSourceMetadataBox(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            bundleURLPath: bundleURLPath
        )
    }

    static func == (
        lhs: ClipboardSourceMetadataBox,
        rhs: ClipboardSourceMetadataBox
    ) -> Bool {
        lhs.displayName == rhs.displayName
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.bundleURLPath == rhs.bundleURLPath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(displayName)
        hasher.combine(bundleIdentifier)
        hasher.combine(bundleURLPath)
    }
}

private final class ClipboardPinStateBox: Sendable {
    let isPinned: Bool
    let pinnedOrder: Int?
    let isDesktopPinned: Bool?
    let desktopPinnedOrder: Int?

    init(
        isPinned: Bool,
        pinnedOrder: Int?,
        isDesktopPinned: Bool?,
        desktopPinnedOrder: Int?
    ) {
        self.isPinned = isPinned
        self.pinnedOrder = pinnedOrder
        self.isDesktopPinned = isDesktopPinned
        self.desktopPinnedOrder = desktopPinnedOrder
    }
}

/// Almost every history row is neither list-pinned nor desktop-pinned. Keep
/// both the current default (`false`) and legacy missing desktop flag (`nil`)
/// as allocation-free enum cases; only the small pinned/compatibility subset
/// needs a box. The box is immutable so copied entries retain value semantics.
private enum ClipboardPinState: Sendable {
    case ordinary
    case legacy
    case custom(ClipboardPinStateBox)

    static func make(
        isPinned: Bool,
        pinnedOrder: Int?,
        isDesktopPinned: Bool?,
        desktopPinnedOrder: Int?
    ) -> ClipboardPinState {
        if !isPinned, pinnedOrder == nil, desktopPinnedOrder == nil {
            if isDesktopPinned == false { return .ordinary }
            if isDesktopPinned == nil { return .legacy }
        }
        return .custom(
            ClipboardPinStateBox(
                isPinned: isPinned,
                pinnedOrder: pinnedOrder,
                isDesktopPinned: isDesktopPinned,
                desktopPinnedOrder: desktopPinnedOrder
            )
        )
    }

    var values: (
        isPinned: Bool,
        pinnedOrder: Int?,
        isDesktopPinned: Bool?,
        desktopPinnedOrder: Int?
    ) {
        switch self {
        case .ordinary:
            (false, nil, false, nil)
        case .legacy:
            (false, nil, nil, nil)
        case .custom(let box):
            (
                box.isPinned,
                box.pinnedOrder,
                box.isDesktopPinned,
                box.desktopPinnedOrder
            )
        }
    }
}

/// The two optional usage statistics have four exact combinations. A value enum
/// represents all of them without heap allocation and without two independent
/// Optional payload/tag/alignment regions in every history row.
private enum ClipboardUsageState: Sendable {
    case unused
    case date(Date)
    case count(Int)
    case used(Date, Int)

    static func make(
        lastUsedAt: Date?,
        useCount: Int?
    ) -> ClipboardUsageState {
        switch (lastUsedAt, useCount) {
        case (nil, nil): .unused
        case (.some(let date), nil): .date(date)
        case (nil, .some(let count)): .count(count)
        case (.some(let date), .some(let count)): .used(date, count)
        }
    }

    var values: (lastUsedAt: Date?, useCount: Int?) {
        switch self {
        case .unused: (nil, nil)
        case .date(let date): (date, nil)
        case .count(let count): (nil, count)
        case .used(let date, let count): (date, count)
        }
    }
}

/// Packs the entry kind, optional origin and optional cached automatic category
/// into one byte. These three values have only 2 × 3 × 7 valid combinations;
/// storing them as three independent enum fields left alignment gaps in every
/// `ClipboardEntry` held by the history array.
private struct ClipboardEntryClassificationBits: Hashable, Sendable {
    private var rawValue: UInt8

    init(
        kind: ClipboardEntryKind,
        origin: ClipboardEntryOrigin?,
        automaticCategory: ClipboardContentCategory?
    ) {
        rawValue = 0
        self.kind = kind
        self.origin = origin
        self.automaticCategory = automaticCategory
    }

    var kind: ClipboardEntryKind {
        get { rawValue & 0b1 == 0 ? .text : .image }
        set {
            rawValue = (rawValue & ~UInt8(0b1))
                | (newValue == .image ? 1 : 0)
        }
    }

    var origin: ClipboardEntryOrigin? {
        get {
            switch (rawValue >> 1) & 0b11 {
            case 1: .hedgeMemoScreenshot
            case 2: .concealedPassword
            default: nil
            }
        }
        set {
            let code: UInt8
            switch newValue {
            case .hedgeMemoScreenshot: code = 1
            case .concealedPassword: code = 2
            case nil: code = 0
            }
            rawValue = (rawValue & ~UInt8(0b110)) | (code << 1)
        }
    }

    var automaticCategory: ClipboardContentCategory? {
        get {
            switch (rawValue >> 3) & 0b111 {
            case 1: .text
            case 2: .code
            case 3: .link
            case 4: .image
            case 5: .screenshot
            case 6: .password
            default: nil
            }
        }
        set {
            let code: UInt8
            switch newValue {
            case .text: code = 1
            case .code: code = 2
            case .link: code = 3
            case .image: code = 4
            case .screenshot: code = 5
            case .password: code = 6
            case nil: code = 0
            }
            rawValue = (rawValue & ~UInt8(0b11_1000)) | (code << 3)
        }
    }
}

public struct ClipboardEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    private var classificationBits: ClipboardEntryClassificationBits
    public var kind: ClipboardEntryKind {
        get { classificationBits.kind }
        set { classificationBits.kind = newValue }
    }
    private var textState: ClipboardTextState
    public var text: String? {
        get {
            switch textState {
            case .resident(let box): box.value
            case .deferred(let provider): provider.text(for: id)
            case .metadata: nil
            }
        }
        set {
            textState = .resident(ClipboardTextBox(newValue))
            automaticContentCategoryValue = nil
        }
    }
    public var imageFileName: String?
    var compactContentHash: CompactContentHash
    public var contentHash: String {
        get { compactContentHash.stringValue }
        set { compactContentHash = CompactContentHash(newValue) }
    }
    public var createdAt: Date
    public var updatedAt: Date
    private var usageState: ClipboardUsageState
    public var lastUsedAt: Date? {
        get { usageState.values.lastUsedAt }
        set {
            usageState = ClipboardUsageState.make(
                lastUsedAt: newValue,
                useCount: usageState.values.useCount
            )
        }
    }
    public var useCount: Int? {
        get { usageState.values.useCount }
        set {
            usageState = ClipboardUsageState.make(
                lastUsedAt: usageState.values.lastUsedAt,
                useCount: newValue
            )
        }
    }
    private var sourceMetadata: ClipboardSourceMetadataBox?
    public var sourceApp: String? {
        get { sourceMetadata?.displayName }
        set {
            replaceSourceMetadata(
                displayName: newValue,
                bundleIdentifier: sourceBundleIdentifier,
                bundleURLPath: sourceBundleURLPath
            )
        }
    }
    /// Stable source identity added after `sourceApp`. Optional fields keep old
    /// clipboard-history snapshots source-compatible.
    public var sourceBundleIdentifier: String? {
        get { sourceMetadata?.bundleIdentifier }
        set {
            replaceSourceMetadata(
                displayName: sourceApp,
                bundleIdentifier: newValue,
                bundleURLPath: sourceBundleURLPath
            )
        }
    }
    public var sourceBundleURLPath: String? {
        get { sourceMetadata?.bundleURLPath }
        set {
            replaceSourceMetadata(
                displayName: sourceApp,
                bundleIdentifier: sourceBundleIdentifier,
                bundleURLPath: newValue
            )
        }
    }
    /// Original RTF/RTFD/HTML representations, stored as sidecar files.
    /// Optional keeps snapshots written before rich-text capture compatible.
    public var originalFormats: [ClipboardOriginalFormat]?
    private var pinState: ClipboardPinState
    public var isPinned: Bool {
        get { pinState.values.isPinned }
        set {
            let current = pinState.values
            replacePinState(
                isPinned: newValue,
                pinnedOrder: current.pinnedOrder,
                isDesktopPinned: current.isDesktopPinned,
                desktopPinnedOrder: current.desktopPinnedOrder
            )
        }
    }
    public var pinnedOrder: Int? {
        get { pinState.values.pinnedOrder }
        set {
            let current = pinState.values
            replacePinState(
                isPinned: current.isPinned,
                pinnedOrder: newValue,
                isDesktopPinned: current.isDesktopPinned,
                desktopPinnedOrder: current.desktopPinnedOrder
            )
        }
    }
    /// Independent from clipboard ordering/quick-slot pinning. Optional keeps
    /// snapshots written by older versions source-compatible when decoded.
    public var isDesktopPinned: Bool? {
        get { pinState.values.isDesktopPinned }
        set {
            let current = pinState.values
            replacePinState(
                isPinned: current.isPinned,
                pinnedOrder: current.pinnedOrder,
                isDesktopPinned: newValue,
                desktopPinnedOrder: current.desktopPinnedOrder
            )
        }
    }
    /// Stable first-pin order for the temporary desktop-pinned section in the
    /// clipboard panel. Optional preserves snapshots written before that section
    /// existed; the store migrates missing values on load.
    public var desktopPinnedOrder: Int? {
        get { pinState.values.desktopPinnedOrder }
        set {
            let current = pinState.values
            replacePinState(
                isPinned: current.isPinned,
                pinnedOrder: current.pinnedOrder,
                isDesktopPinned: current.isDesktopPinned,
                desktopPinnedOrder: newValue
            )
        }
    }
    public var origin: ClipboardEntryOrigin? {
        get { classificationBits.origin }
        set { classificationBits.origin = newValue }
    }
    /// Optional storage value of a user-selected category. Nil keeps automatic
    /// content/regex classification. A string keeps older snapshots compatible
    /// and supports both built-in and custom category keys.
    public var manualCategoryStorageValue: String?
    /// Cached automatic classification. Persisting this small value lets the
    /// process keep text bodies out of memory while filtering built-in
    /// categories. Optional preserves snapshots created by older releases.
    private var automaticContentCategoryValue: ClipboardContentCategory? {
        get { classificationBits.automaticCategory }
        set { classificationBits.automaticCategory = newValue }
    }

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
        sourceBundleIdentifier: String? = nil,
        sourceBundleURLPath: String? = nil,
        originalFormats: [ClipboardOriginalFormat]? = nil,
        isPinned: Bool = false,
        pinnedOrder: Int? = nil,
        isDesktopPinned: Bool? = false,
        desktopPinnedOrder: Int? = nil,
        origin: ClipboardEntryOrigin? = nil,
        manualCategoryStorageValue: String? = nil
    ) {
        self.id = id
        self.classificationBits = ClipboardEntryClassificationBits(
            kind: kind,
            origin: origin,
            automaticCategory: Self.automaticCategory(
                kind: kind,
                text: text,
                origin: origin
            )
        )
        self.textState = .resident(ClipboardTextBox(text))
        self.imageFileName = imageFileName
        self.compactContentHash = CompactContentHash(contentHash)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageState = ClipboardUsageState.make(
            lastUsedAt: lastUsedAt,
            useCount: useCount
        )
        self.sourceMetadata = ClipboardSourceMetadataBox.make(
            displayName: sourceApp,
            bundleIdentifier: sourceBundleIdentifier,
            bundleURLPath: sourceBundleURLPath
        )
        self.originalFormats = originalFormats
        self.pinState = ClipboardPinState.make(
            isPinned: isPinned,
            pinnedOrder: pinnedOrder,
            isDesktopPinned: isDesktopPinned,
            desktopPinnedOrder: desktopPinnedOrder
        )
        self.manualCategoryStorageValue = manualCategoryStorageValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFileName, contentHash, createdAt, updatedAt
        case lastUsedAt, useCount, sourceApp, sourceBundleIdentifier
        case sourceBundleURLPath, originalFormats, isPinned, pinnedOrder
        case isDesktopPinned, desktopPinnedOrder, origin
        case manualCategoryStorageValue, automaticContentCategoryStorageValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let decodedKind = try container.decode(
            ClipboardEntryKind.self,
            forKey: .kind
        )
        textState = .resident(
            ClipboardTextBox(
                try container.decodeIfPresent(String.self, forKey: .text)
            )
        )
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        compactContentHash = CompactContentHash(
            try container.decode(String.self, forKey: .contentHash)
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        usageState = ClipboardUsageState.make(
            lastUsedAt: try container.decodeIfPresent(
                Date.self,
                forKey: .lastUsedAt
            ),
            useCount: try container.decodeIfPresent(
                Int.self,
                forKey: .useCount
            )
        )
        sourceMetadata = ClipboardSourceMetadataBox.make(
            displayName: try container.decodeIfPresent(String.self, forKey: .sourceApp),
            bundleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .sourceBundleIdentifier
            ),
            bundleURLPath: try container.decodeIfPresent(
                String.self,
                forKey: .sourceBundleURLPath
            )
        )
        originalFormats = try container.decodeIfPresent([ClipboardOriginalFormat].self, forKey: .originalFormats)
        pinState = ClipboardPinState.make(
            isPinned: try container.decodeIfPresent(
                Bool.self,
                forKey: .isPinned
            ) ?? false,
            pinnedOrder: try container.decodeIfPresent(
                Int.self,
                forKey: .pinnedOrder
            ),
            isDesktopPinned: try container.decodeIfPresent(
                Bool.self,
                forKey: .isDesktopPinned
            ),
            desktopPinnedOrder: try container.decodeIfPresent(
                Int.self,
                forKey: .desktopPinnedOrder
            )
        )
        let decodedOrigin = try container.decodeIfPresent(
            ClipboardEntryOrigin.self,
            forKey: .origin
        )
        manualCategoryStorageValue = try container.decodeIfPresent(
            String.self,
            forKey: .manualCategoryStorageValue
        )
        let decodedAutomaticCategory = try container.decodeIfPresent(
            String.self,
            forKey: .automaticContentCategoryStorageValue
        ).flatMap(ClipboardContentCategory.init(rawValue:))
        classificationBits = ClipboardEntryClassificationBits(
            kind: decodedKind,
            origin: decodedOrigin,
            automaticCategory: decodedAutomaticCategory
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(useCount, forKey: .useCount)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(sourceBundleIdentifier, forKey: .sourceBundleIdentifier)
        try container.encodeIfPresent(sourceBundleURLPath, forKey: .sourceBundleURLPath)
        try container.encodeIfPresent(originalFormats, forKey: .originalFormats)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(pinnedOrder, forKey: .pinnedOrder)
        try container.encodeIfPresent(isDesktopPinned, forKey: .isDesktopPinned)
        try container.encodeIfPresent(desktopPinnedOrder, forKey: .desktopPinnedOrder)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(manualCategoryStorageValue, forKey: .manualCategoryStorageValue)
        try container.encodeIfPresent(
            automaticContentCategoryValue?.rawValue,
            forKey: .automaticContentCategoryStorageValue
        )
    }

    public static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.classificationBits == rhs.classificationBits
            && lhs.imageFileName == rhs.imageFileName
            && lhs.compactContentHash == rhs.compactContentHash
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.lastUsedAt == rhs.lastUsedAt
            && lhs.useCount == rhs.useCount
            && lhs.sourceApp == rhs.sourceApp
            && lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier
            && lhs.sourceBundleURLPath == rhs.sourceBundleURLPath
            && lhs.originalFormats == rhs.originalFormats
            && lhs.isPinned == rhs.isPinned
            && lhs.pinnedOrder == rhs.pinnedOrder
            && lhs.isDesktopPinned == rhs.isDesktopPinned
            && lhs.desktopPinnedOrder == rhs.desktopPinnedOrder
            && lhs.manualCategoryStorageValue == rhs.manualCategoryStorageValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(classificationBits)
        hasher.combine(imageFileName)
        hasher.combine(compactContentHash)
        hasher.combine(createdAt)
        hasher.combine(updatedAt)
        hasher.combine(lastUsedAt)
        hasher.combine(useCount)
        hasher.combine(sourceApp)
        hasher.combine(sourceBundleIdentifier)
        hasher.combine(sourceBundleURLPath)
        hasher.combine(originalFormats)
        hasher.combine(isPinned)
        hasher.combine(pinnedOrder)
        hasher.combine(isDesktopPinned)
        hasher.combine(desktopPinnedOrder)
        hasher.combine(manualCategoryStorageValue)
    }

    mutating func deferText(
        to provider: ClipboardEntryTextProvider,
        automaticCategory: ClipboardContentCategory
    ) {
        automaticContentCategoryValue = automaticCategory
        textState = .deferred(provider)
    }

    var metadataProjection: ClipboardEntry {
        var projection = self
        projection.textState = .metadata
        return projection
    }

    var requiresDeferredTextRead: Bool {
        if case .deferred = textState { return true }
        return false
    }

    /// Resolves a deferred body once for a database row. Encoding `self`
    /// directly and then reading `text` separately asks a non-caching import
    /// provider for the same potentially large string twice.
    var persistenceProjection: (entry: ClipboardEntry, text: String?) {
        let resolvedText: String?
        switch textState {
        case .resident(let box):
            resolvedText = box.value
        case .deferred(let provider):
            resolvedText = provider.textForPersistence(for: id)
        case .metadata:
            resolvedText = nil
        }
        var projection = self
        projection.textState = .resident(
            ClipboardTextBox(resolvedText)
        )
        return (projection, resolvedText)
    }

    func redirectDeferredText(to provider: ClipboardEntryTextProvider) {
        guard case .deferred(let currentProvider) = textState else { return }
        currentProvider.redirect(to: provider)
    }

    var decodedStoredText: String? {
        guard case .resident(let box) = textState else { return nil }
        return box.value
    }

    var automaticContentCategory: ClipboardContentCategory {
        if let cached = automaticContentCategoryValue {
            return cached
        }
        return Self.automaticCategory(kind: kind, text: text, origin: origin)
    }

    static var storageStride: Int { MemoryLayout<Self>.stride }
    static var textStateStorageStride: Int {
        MemoryLayout<ClipboardTextState>.stride
    }
    static var sourceMetadataStorageStride: Int {
        MemoryLayout<ClipboardSourceMetadataBox?>.stride
    }
    #if DEBUG
    static var pinStateStorageStride: Int {
        MemoryLayout<ClipboardPinState>.stride
    }
    static var usageStateStorageStride: Int {
        MemoryLayout<ClipboardUsageState>.stride
    }
    var hasAllocatedPinStateForTesting: Bool {
        if case .custom = pinState { return true }
        return false
    }
    #endif

    var sourceMetadataBoxForInterning: ClipboardSourceMetadataBox? {
        sourceMetadata
    }

    mutating func replaceSourceMetadata(
        displayName: String?,
        bundleIdentifier: String?,
        bundleURLPath: String?
    ) {
        sourceMetadata = ClipboardSourceMetadataBox.make(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            bundleURLPath: bundleURLPath
        )
    }

    mutating func reuseSourceMetadataBox(_ box: ClipboardSourceMetadataBox?) {
        sourceMetadata = box
    }

    private mutating func replacePinState(
        isPinned: Bool,
        pinnedOrder: Int?,
        isDesktopPinned: Bool?,
        desktopPinnedOrder: Int?
    ) {
        pinState = ClipboardPinState.make(
            isPinned: isPinned,
            pinnedOrder: pinnedOrder,
            isDesktopPinned: isDesktopPinned,
            desktopPinnedOrder: desktopPinnedOrder
        )
    }

    /// Persisted password entries default to a mask. Once the password category
    /// is unlocked, the panel may create an ephemeral copy whose `text` is
    /// plaintext for display; the stored model, search index and archive
    /// snapshot remain encrypted or masked.
    public var isSecret: Bool { origin == .concealedPassword }

    public var sourceApplication: ClipboardSourceApplication? {
        guard sourceApp != nil || sourceBundleIdentifier != nil || sourceBundleURLPath != nil else {
            return nil
        }
        return ClipboardSourceApplication(
            bundleIdentifier: sourceBundleIdentifier,
            displayName: sourceApp ?? L10n.text("未知"),
            bundleURLPath: sourceBundleURLPath
        )
    }

    public var manualCategoryKey: ClipboardCategoryKey? {
        manualCategoryStorageValue.flatMap(ClipboardCategoryKey.init(storageValue:))
    }

    /// Prevents manual choices that would make a row render with an incompatible
    /// cell type. Text can move into or out of the password category (the store
    /// performs the required encryption transition), while images stay within
    /// image-style categories.
    public func supportsManualCategory(_ key: ClipboardCategoryKey) -> Bool {
        switch (kind, key) {
        case (.text, .builtin(.text)),
             (.text, .builtin(.code)),
             (.text, .builtin(.link)),
             (.text, .builtin(.password)),
             (.text, .custom),
             (.image, .custom):
            return true
        case (.image, .builtin(.image)),
             (.image, .builtin(.screenshot)):
            return true
        default:
            return false
        }
    }

    public var previewText: String {
        if isSecret { return L10n.text("已隐藏的密码") }
        switch kind {
        case .text:
            let cleaned = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? L10n.text("空白文字") : cleaned
        case .image:
            return text?.isEmpty == false ? text! : L10n.text("图片")
        }
    }

    /// Produces a non-persisted value for the unlocked password UI. Passing nil
    /// deliberately removes ciphertext so a failed decryption renders the
    /// normal mask instead of exposing the encrypted envelope.
    public func displayProjection(revealedSecret: String?) -> ClipboardEntry {
        guard isSecret else { return self }
        var projection = self
        projection.text = revealedSecret
        return projection
    }

    public var contentCategory: ClipboardContentCategory {
        if origin == .concealedPassword { return .password }
        if case .builtin(let category) = manualCategoryKey { return category }
        if origin == .hedgeMemoScreenshot { return .screenshot }
        return automaticContentCategory
    }

    private static func automaticCategory(
        kind: ClipboardEntryKind,
        text: String?,
        origin: ClipboardEntryOrigin?
    ) -> ClipboardContentCategory {
        if origin == .concealedPassword { return .password }
        if origin == .hedgeMemoScreenshot { return .screenshot }
        switch kind {
        case .image:
            return .image
        case .text:
            let value = text ?? ""
            if ClipboardLinkDetector.isLink(value) { return .link }
            if ClipboardCodeDetector.isCode(value) { return .code }
            return .text
        }
    }

    public func matches(query: String) -> Bool {
        matches(matcher: PercentFuzzyMatcher(query: query))
    }

    public func matches(matcher: PercentFuzzyMatcher) -> Bool {
        matchesQuery(matcher)
    }

    /// Query matching without materializing `previewText`.
    ///
    /// `previewText` trims the stored text, which allocates a full copy of
    /// every candidate — over a large history that is a second copy of the
    /// entire text corpus, produced again whenever the list changes. The
    /// matcher's own pattern is already trimmed, so leading/trailing
    /// whitespace in the candidate cannot change a match; searching the stored
    /// text directly is equivalent everywhere except for the placeholder text
    /// shown in place of blank or unlabelled content, which is checked
    /// explicitly below.
    public func matchesQuery(_ matcher: PercentFuzzyMatcher) -> Bool {
        if matcher.matchesEveryCandidate { return true }
        if isSecret { return matcher.matches(L10n.text("已隐藏的密码")) }
        switch kind {
        case .text:
            guard let text, let first = text.first else {
                return matcher.matches(L10n.text("空白文字"))
            }
            if matcher.matches(text) { return true }
            // Only a candidate that starts with whitespace can be blank all
            // the way through, so the full scan stays off the common path.
            guard first.isWhitespace, text.allSatisfy(\.isWhitespace) else { return false }
            return matcher.matches(L10n.text("空白文字"))
        case .image:
            if let text, !text.isEmpty { return matcher.matches(text) }
            return matcher.matches(L10n.text("图片"))
        }
    }

    public func matches(key: ClipboardCategoryKey?, customCategories: [CustomClipboardCategory] = []) -> Bool {
        if let manualCategoryKey {
            return key == nil || key == manualCategoryKey
        }
        switch key {
        case nil:
            return true
        case .builtin(let category):
            return contentCategory == category
        case .custom(let id):
            guard let custom = customCategories.first(where: { $0.id == id }) else { return false }
            return custom.matches(self)
        }
    }
}

#if DEBUG
/// Exact pre-1.2.24 stored-field shape used only by layout tests. Keeping the
/// comparison in the same compiler/module makes the byte delta authoritative;
/// this type is absent from release builds.
private struct LegacyClipboardEntryLayout {
    let id: UUID
    var kind: ClipboardEntryKind
    var storedText: String?
    var deferredTextProvider: ClipboardEntryTextProvider?
    var imageFileName: String?
    var compactContentHash: CompactContentHash
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int?
    var sourceApp: String?
    var sourceBundleIdentifier: String?
    var sourceBundleURLPath: String?
    var originalFormats: [ClipboardOriginalFormat]?
    var isPinned: Bool
    var pinnedOrder: Int?
    var isDesktopPinned: Bool?
    var desktopPinnedOrder: Int?
    var origin: ClipboardEntryOrigin?
    var manualCategoryStorageValue: String?
    var automaticContentCategoryStorageValue: String?
}

/// Exact 1.2.25 layout after classification packing but before the resident /
/// deferred / metadata text-state union.
private struct LegacyClipboardEntryTextLayout {
    let id: UUID
    var classificationBits: ClipboardEntryClassificationBits
    var storedText: String?
    var deferredTextProvider: ClipboardEntryTextProvider?
    var imageFileName: String?
    var compactContentHash: CompactContentHash
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int?
    var sourceApp: String?
    var sourceBundleIdentifier: String?
    var sourceBundleURLPath: String?
    var originalFormats: [ClipboardOriginalFormat]?
    var isPinned: Bool
    var pinnedOrder: Int?
    var isDesktopPinned: Bool?
    var desktopPinnedOrder: Int?
    var manualCategoryStorageValue: String?
}

/// Exact 1.2.26 layout before the three source strings were coalesced behind a
/// shared immutable metadata reference.
private struct LegacyClipboardEntrySourceLayout {
    let id: UUID
    var classificationBits: ClipboardEntryClassificationBits
    var textState: ClipboardTextState
    var imageFileName: String?
    var compactContentHash: CompactContentHash
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int?
    var sourceApp: String?
    var sourceBundleIdentifier: String?
    var sourceBundleURLPath: String?
    var originalFormats: [ClipboardOriginalFormat]?
    var isPinned: Bool
    var pinnedOrder: Int?
    var isDesktopPinned: Bool?
    var desktopPinnedOrder: Int?
    var manualCategoryStorageValue: String?
}

/// Exact 1.2.27 layout before quick-pin and desktop-pin fields were coalesced
/// into their common-case allocation-free state.
private struct LegacyClipboardEntryPinLayout {
    let id: UUID
    var classificationBits: ClipboardEntryClassificationBits
    var textState: ClipboardTextState
    var imageFileName: String?
    var compactContentHash: CompactContentHash
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int?
    var sourceMetadata: ClipboardSourceMetadataBox?
    var originalFormats: [ClipboardOriginalFormat]?
    var isPinned: Bool
    var pinnedOrder: Int?
    var isDesktopPinned: Bool?
    var desktopPinnedOrder: Int?
    var manualCategoryStorageValue: String?
}

/// Exact 1.2.28 layout before the two optional usage statistics were represented
/// as one four-case, heap-free value state.
private struct LegacyClipboardEntryUsageLayout {
    let id: UUID
    var classificationBits: ClipboardEntryClassificationBits
    var textState: ClipboardTextState
    var imageFileName: String?
    var compactContentHash: CompactContentHash
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int?
    var sourceMetadata: ClipboardSourceMetadataBox?
    var originalFormats: [ClipboardOriginalFormat]?
    var pinState: ClipboardPinState
    var manualCategoryStorageValue: String?
}

extension ClipboardEntry {
    static var legacyStorageStrideForTesting: Int {
        MemoryLayout<LegacyClipboardEntryLayout>.stride
    }

    static var legacyTextStorageStrideForTesting: Int {
        MemoryLayout<LegacyClipboardEntryTextLayout>.stride
    }

    static var legacySourceStorageStrideForTesting: Int {
        MemoryLayout<LegacyClipboardEntrySourceLayout>.stride
    }

    static var legacyPinStorageStrideForTesting: Int {
        MemoryLayout<LegacyClipboardEntryPinLayout>.stride
    }

    static var legacyUsageStorageStrideForTesting: Int {
        MemoryLayout<LegacyClipboardEntryUsageLayout>.stride
    }
}
#endif

public struct ClipboardHistorySnapshot: Codable, Sendable {
    public var entries: [ClipboardEntry]
    public var settings: ClipboardHistorySettings

    public init(entries: [ClipboardEntry] = [], settings: ClipboardHistorySettings = ClipboardHistorySettings()) {
        self.entries = entries
        self.settings = settings
    }
}

public enum ClipboardHistoryPolicy {
    package struct SortedPartitions {
        package var ordinary: [ClipboardEntry]
        package var desktopPinned: [ClipboardEntry]
    }

    /// Desktop notes occupy a stable section beginning at the tenth visible
    /// position. The first nine regular/list-pinned results keep their familiar
    /// command-number slots; desktop-pinned items are then ordered first-pinned
    /// first. When fewer than nine other entries exist, no fake blank rows are
    /// introduced and the section follows the available entries immediately.
    public static let desktopPinnedInsertionIndex = 9

    public static func ordered(
        _ entries: [ClipboardEntry],
        query: String = "",
        key: ClipboardCategoryKey? = nil,
        customCategories: [CustomClipboardCategory] = [],
        advancedOptions: ClipboardAdvancedOptions? = nil
    ) -> [ClipboardEntry] {
        ordered(
            sortedPartitions(entries, advancedOptions: advancedOptions),
            query: query,
            key: key,
            customCategories: customCategories,
            advancedOptions: advancedOptions
        )
    }

    /// Sorting is independent of query, category and source selection. Stores
    /// can retain one transient partition while the panel is open and reuse it
    /// for each character typed into search.
    package static func sortedPartitions(
        _ entries: [ClipboardEntry],
        advancedOptions: ClipboardAdvancedOptions?
    ) -> SortedPartitions {
        var desktopPinned: [ClipboardEntry] = []
        var ordinary: [ClipboardEntry] = []
        desktopPinned.reserveCapacity(min(entries.count, 32))
        ordinary.reserveCapacity(entries.count)
        for entry in entries {
            if entry.isDesktopPinned == true {
                desktopPinned.append(entry)
            } else {
                ordinary.append(entry)
            }
        }

        desktopPinned.sort {
            let left = $0.desktopPinnedOrder ?? Int.max
            let right = $1.desktopPinnedOrder ?? Int.max
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.createdAt < $1.createdAt
        }
        ordinary.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.isPinned {
                return (lhs.pinnedOrder ?? Int.max) < (rhs.pinnedOrder ?? Int.max)
            }
            return advancedOptions?.comesBefore(lhs, rhs) ?? (lhs.createdAt > rhs.createdAt)
        }
        return SortedPartitions(ordinary: ordinary, desktopPinned: desktopPinned)
    }

    package static func ordered(
        _ partitions: SortedPartitions,
        query: String,
        key: ClipboardCategoryKey?,
        customCategories: [CustomClipboardCategory],
        advancedOptions: ClipboardAdvancedOptions?
    ) -> [ClipboardEntry] {
        assembled(
            queryFiltered(
                categoryFiltered(
                    partitions,
                    key: key,
                    customCategories: customCategories,
                    advancedOptions: advancedOptions
                ),
                matcher: PercentFuzzyMatcher(query: query)
            )
        )
    }

    /// The category/source half of filtering, which does not depend on the
    /// search query. It is the expensive half — a built-in category asks every
    /// entry to classify itself, and a custom one runs its rules (including
    /// regular expressions) over every entry. Stores keep this result for the
    /// open category so that typing in the search field re-runs only the
    /// matcher, instead of re-classifying the whole history per keystroke.
    package static func categoryFiltered(
        _ partitions: SortedPartitions,
        key: ClipboardCategoryKey?,
        customCategories: [CustomClipboardCategory],
        advancedOptions: ClipboardAdvancedOptions?
    ) -> SortedPartitions {
        // Nothing to reject: hand back the same storage instead of copying
        // every element into a new array.
        if key == nil, advancedOptions?.sourceIdentifier == nil { return partitions }
        func matches(_ entry: ClipboardEntry) -> Bool {
            entry.matches(key: key, customCategories: customCategories)
                && (advancedOptions?.matchesSource(entry) ?? true)
        }
        return SortedPartitions(
            ordinary: partitions.ordinary.filter(matches),
            desktopPinned: partitions.desktopPinned.filter(matches)
        )
    }

    package static func queryFiltered(
        _ partitions: SortedPartitions,
        matcher: PercentFuzzyMatcher
    ) -> SortedPartitions {
        guard !matcher.matchesEveryCandidate else { return partitions }
        return SortedPartitions(
            ordinary: partitions.ordinary.filter { $0.matchesQuery(matcher) },
            desktopPinned: partitions.desktopPinned.filter { $0.matchesQuery(matcher) }
        )
    }

    /// Splices the desktop-note section into its fixed position. The insertion
    /// index is recomputed from the filtered ordinary list, so a search result
    /// places the section exactly where an unfiltered list would.
    package static func assembled(_ partitions: SortedPartitions) -> [ClipboardEntry] {
        let ordinary = partitions.ordinary
        let desktopPinned = partitions.desktopPinned
        guard !desktopPinned.isEmpty else { return ordinary }
        let insertion = min(desktopPinnedInsertionIndex, ordinary.count)
        var result: [ClipboardEntry] = []
        result.reserveCapacity(ordinary.count + desktopPinned.count)
        result.append(contentsOf: ordinary[..<insertion])
        result.append(contentsOf: desktopPinned)
        result.append(contentsOf: ordinary[insertion...])
        return result
    }

    public static func pinnedEntries(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter(\.isPinned).sorted { lhs, rhs in
            let left = lhs.pinnedOrder ?? Int.max
            let right = rhs.pinnedOrder ?? Int.max
            if left != right { return left < right }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public static func desktopPinnedEntries(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter { $0.isDesktopPinned == true }.sorted { lhs, rhs in
            let left = lhs.desktopPinnedOrder ?? Int.max
            let right = rhs.desktopPinnedOrder ?? Int.max
            if left != right { return left < right }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public static func quickEntry(in entries: [ClipboardEntry], number: Int) -> ClipboardEntry? {
        guard (1...9).contains(number) else { return nil }
        // The quick slots are reachable without opening any category, so they
        // must never hand back a secret — that would be a copy of a password
        // with no gate in front of it.
        let pinned = pinnedEntries(entries).filter { !$0.isSecret }
        guard number <= pinned.count else { return nil }
        return pinned[number - 1]
    }

    public static func idsToTrim(from entries: [ClipboardEntry], maxEntries: Int) -> [UUID] {
        let maxEntries = max(10, maxEntries)
        guard entries.count > maxEntries else { return [] }
        // Both pin modes are user promises, so automatic history trimming must
        // never silently delete either kind. If protected entries alone exceed
        // the configured limit, retain them and trim every ordinary entry.
        func isRemovable(_ entry: ClipboardEntry) -> Bool {
            !entry.isPinned && entry.isDesktopPinned != true
        }
        var removableCount = 0
        for entry in entries where isRemovable(entry) { removableCount += 1 }
        let overflow = min(entries.count - maxEntries, removableCount)
        guard overflow > 0 else { return [] }

        // A history sitting at its limit trims one entry per capture. Selecting
        // the few oldest with a bounded scan keeps that path linear, where
        // sorting every removable entry made each copy cost O(n log n) over the
        // whole history.
        guard overflow > Self.boundedTrimSelectionLimit else {
            var oldest: [(date: Date, id: UUID)] = []
            oldest.reserveCapacity(overflow)
            for entry in entries where isRemovable(entry) {
                if oldest.count == overflow {
                    guard let newest = oldest.last, newest.date > entry.createdAt else { continue }
                    oldest.removeLast()
                }
                let position = oldest.firstIndex { $0.date > entry.createdAt } ?? oldest.endIndex
                oldest.insert((entry.createdAt, entry.id), at: position)
            }
            return oldest.map(\.id)
        }

        let removable = entries
            .filter(isRemovable)
            .sorted { $0.createdAt < $1.createdAt }
        return removable.prefix(overflow).map(\.id)
    }

    /// Above this many entries at once (a limit change, an import), a single
    /// sort beats repeated bounded insertion.
    private static let boundedTrimSelectionLimit = 32
}

public enum ScreenshotMode: String, Codable, CaseIterable, Sendable {
    case manualSelection
    case smartWindow

    public var displayName: String {
        switch self {
        case .manualSelection: L10n.text("手动框选")
        case .smartWindow: L10n.text("智能窗口")
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

/// User preference for opening the meme picker. It lives separately from the
/// library snapshot because changing a shortcut must not rewrite image data.
public struct MemePanelSettings: Codable, Equatable, Sendable {
    public var hotKey: HotKeyDefinition

    public init(hotKey: HotKeyDefinition = .defaultMemePanel) {
        self.hotKey = hotKey
    }
}
