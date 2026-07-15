import Foundation
import Testing
@testable import MemeMemoCore

struct MemeFilterTests {
    @Test("Searches both user notes and OCR text")
    func searchesNotesAndOCRText() {
        let noteMatch = MemeItem(fileName: "a.png", contentHash: "a", note: "周五下班", ocrText: "")
        let ocrMatch = MemeItem(fileName: "b.png", contentHash: "b", note: "未命名", ocrText: "你好世界")

        #expect(MemeFilter.apply([noteMatch, ocrMatch], categoryID: nil, query: "下班").map(\.id) == [noteMatch.id])
        #expect(MemeFilter.apply([noteMatch, ocrMatch], categoryID: nil, query: "世界").map(\.id) == [ocrMatch.id])
    }

    @Test("Filters categories and preserves saved order")
    func filtersByCategoryAndSortOrder() {
        let category = UUID()
        let first = MemeItem(fileName: "first.png", contentHash: "1", categoryID: category, sortOrder: 0)
        let second = MemeItem(fileName: "second.png", contentHash: "2", categoryID: category, sortOrder: 1)
        let other = MemeItem(fileName: "other.png", contentHash: "3", sortOrder: 0)

        #expect(MemeFilter.apply([second, other, first], categoryID: category, query: "").map(\.id) == [first.id, second.id])
    }

    @Test("A blank query retains all entries")
    func blankQueryRetainsAllEntries() {
        let meme = MemeItem(fileName: "a.png", contentHash: "hash", note: "一张图")
        #expect(meme.matches(query: "  "))
    }
}
