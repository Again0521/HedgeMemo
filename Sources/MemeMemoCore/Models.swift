import Foundation

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
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return note.localizedCaseInsensitiveContains(normalized)
            || ocrText.localizedCaseInsensitiveContains(normalized)
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
        memes
            .filter { categoryID == nil || $0.categoryID == categoryID }
            .filter { $0.matches(query: query) }
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

public enum ClipboardContentCategory: String, Codable, CaseIterable, Sendable {
    case all
    case image
    case text
    case code

    public var displayName: String {
        switch self {
        case .all: "全部"
        case .image: "图片"
        case .text: "文字"
        case .code: "代码"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .image: "photo"
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
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

    public static func isCode(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else { return false }
        guard !isLikelyLink(text) else { return false }
        guard cjkRatio(text) <= 0.3 else { return false }
        return score(text) >= 3
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
        guard !text.contains(where: \.isNewline) else { return false }
        let lowered = text.lowercased()
        let prefixes = ["http://", "https://", "ftp://", "magnet:", "mailto:", "file://"]
        return prefixes.contains(where: { lowered.hasPrefix($0) })
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

    public static let defaultClipboard = HotKeyDefinition(keyCode: 49, key: "Space", option: true)
    public static let defaultScreenshot = HotKeyDefinition(keyCode: 23, key: "5", control: true, shift: true)

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

public struct ClipboardHistorySettings: Codable, Equatable, Sendable {
    public var maxEntries: Int
    public var savesImages: Bool
    public var itemSize: ClipboardItemSize
    public var autoPaste: Bool
    public var hotKey: HotKeyDefinition?

    public init(
        maxEntries: Int = 100,
        savesImages: Bool = true,
        itemSize: ClipboardItemSize = .regular,
        autoPaste: Bool = false,
        hotKey: HotKeyDefinition? = .defaultClipboard
    ) {
        self.maxEntries = max(10, min(maxEntries, 1_000))
        self.savesImages = savesImages
        self.itemSize = itemSize
        self.autoPaste = autoPaste
        self.hotKey = hotKey
    }

    public mutating func normalize() {
        maxEntries = max(10, min(maxEntries, 1_000))
        if hotKey == nil { hotKey = .defaultClipboard }
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
    public var isPinned: Bool
    public var pinnedOrder: Int?

    public init(
        id: UUID = UUID(),
        kind: ClipboardEntryKind,
        text: String? = nil,
        imageFileName: String? = nil,
        contentHash: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        pinnedOrder: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.pinnedOrder = pinnedOrder
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

    public var contentCategory: ClipboardContentCategory {
        switch kind {
        case .image: .image
        case .text: ClipboardCodeDetector.isCode(text ?? "") ? .code : .text
        }
    }

    public func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return previewText.localizedCaseInsensitiveContains(normalized)
    }

    public func matches(category: ClipboardContentCategory) -> Bool {
        category == .all || contentCategory == category
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
        category: ClipboardContentCategory = .all
    ) -> [ClipboardEntry] {
        entries
            .filter { $0.matches(query: query) && $0.matches(category: category) }
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
    case commandShiftFive
    case controlShiftFive

    public var displayName: String {
        switch self {
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
        mode: ScreenshotMode = .manualSelection,
        remembersLastMode: Bool = true,
        hotKeyChoice: ScreenshotHotKeyChoice = .controlShiftFive,
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
        if hotKey == nil {
            hotKey = switch hotKeyChoice {
            case .commandShiftFive: HotKeyDefinition(keyCode: 23, key: "5", command: true, shift: true)
            case .controlShiftFive: .defaultScreenshot
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
