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
