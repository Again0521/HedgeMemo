import AppKit
import XCTest

@testable import HedgeMemoCore

/// Exercises the stateful stores end to end against throwaway on-disk
/// repositories, so persistence and mutation paths are covered too.
@MainActor
final class StoreBehaviorTests: XCTestCase {
    /// Each temp root registers its own teardown so cleanup captures only a
    /// `Sendable` URL — no main-actor state leaks into the nonisolated teardown.
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeMemeStore() -> MemeStore {
        MemeStore(repository: MemeRepository(rootURL: tempRoot("meme")))
    }

    private func makeClipboardStore() -> ClipboardHistoryStore {
        ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: tempRoot("clip")))
    }

    // MARK: - MemeStore

    func testMemeFilterReturnsSharedProjectionInsteadOfMaterializedItemArray() {
        let items = (0..<20_000).map { index in
            MemeItem(
                fileName: "\(index).png",
                contentHash: "hash-\(index)",
                note: "item-\(index)",
                sortOrder: index
            )
        }

        let identity = MemeFilteredResults(source: items, positions: nil)
        XCTAssertEqual(identity.count, 20_000)
        XCTAssertEqual(identity.retainedPositionCount, 0)
        XCTAssertEqual(identity.first?.id, items.first?.id)
        XCTAssertEqual(identity.last?.id, items.last?.id)

        let evenPositions = Array(stride(from: 0, to: items.count, by: 2))
        let filtered = MemeFilteredResults(
            source: items,
            positions: evenPositions
        )
        XCTAssertEqual(filtered.count, 10_000)
        XCTAssertEqual(filtered.retainedPositionCount, 10_000)
        XCTAssertEqual(filtered[4_999].id, items[9_998].id)
    }

    func testUnfilteredMemeStoreResultRetainsNoRedundantPositionArray() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.1, size: 6), note: "一"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.5, size: 8), note: "二"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.9, size: 10), note: "三"))

        let result = store.filteredMemes(query: "")

        XCTAssertEqual(result.map(\.note), ["一", "二", "三"])
        XCTAssertEqual(result.retainedPositionCount, 0)
    }

    func testMemeFilterMemoKeepsOnlyBoundedRecentQueries() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.1, size: 6), note: "alpha"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.5, size: 8), note: "beta"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.9, size: 10), note: "gamma"))

        for index in 0..<40 {
            _ = store.filteredMemes(query: "unique-query-\(index)")
        }

        XCTAssertLessThanOrEqual(store.filteredMemoMetrics.entryCount, 8)
        XCTAssertLessThanOrEqual(
            store.filteredMemoMetrics.retainedPositionCount,
            100_000
        )
        store.releaseTransientCaches()
        XCTAssertEqual(store.filteredMemoMetrics.entryCount, 0)
        XCTAssertEqual(store.filteredMemoMetrics.retainedPositionCount, 0)
    }

    func testMemeReorderMovesDraggedItemIntoTargetSlot() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.1, size: 6), note: "一"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.5, size: 8), note: "二"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.9, size: 10), note: "三"))
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["一", "二", "三"])

        let first = store.filteredMemes(query: "")[0].id
        let third = store.filteredMemes(query: "")[2].id
        store.reorder(draggedID: first, over: third)
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["二", "三", "一"])

        store.reorderToEnd(draggedID: store.filteredMemes(query: "")[0].id, categoryID: nil)
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["三", "一", "二"])
    }

    func testMemeDragBurstPersistsOnlyFinalSnapshot() {
        let repository = MemeRepository(rootURL: tempRoot("meme-drag-coalescing"))
        let store = MemeStore(repository: repository)
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.1, size: 6), note: "一"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.5, size: 8), note: "二"))
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.9, size: 10), note: "三"))
        store.flushPendingSave()
        let writesBeforeDrag = repository.completedSnapshotWriteCount

        for _ in 0..<20 {
            let visible = store.filteredMemes(query: "")
            store.reorder(draggedID: visible[0].id, over: visible[2].id)
        }
        store.flushPendingSave()

        XCTAssertEqual(
            repository.completedSnapshotWriteCount - writesBeforeDrag,
            1,
            "live drag updates stay immediate but must replace the full manifest only once"
        )
        let reloaded = MemeStore(repository: repository)
        XCTAssertEqual(reloaded.filteredMemes(query: "").map(\.id), store.filteredMemes(query: "").map(\.id))
    }

    func testLegacyMemeJSONMigratesToSQLiteAndRemainsAsBackup() throws {
        let root = tempRoot("meme-sqlite-migration")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("library.json")
        let category = MemeCategory(name: "旧分类")
        let original = MemeSnapshot(
            categories: [category],
            memes: [
                MemeItem(
                    fileName: "legacy.png",
                    contentHash: "legacy-meme",
                    note: "旧表情",
                    categoryID: category.id
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original).write(to: legacyURL, options: .atomic)

        let repository = MemeRepository(rootURL: root)
        let migrated = try repository.load()
        XCTAssertEqual(migrated.categories.map(\.name), ["旧分类"])
        XCTAssertEqual(migrated.memes.map(\.note), ["旧表情"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        try encoder.encode(MemeSnapshot()).write(to: legacyURL, options: .atomic)
        let reloaded = try MemeRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.memes.map(\.note), ["旧表情"])
    }

    func testMemeSQLiteSaveOnlyUpsertsChangedRows() throws {
        let repository = MemeRepository(rootURL: tempRoot("meme-sqlite-delta"))
        let category = MemeCategory(name: "分类")
        var snapshot = MemeSnapshot(
            categories: [category],
            memes: (0..<50).map {
                MemeItem(
                    fileName: "\($0).png",
                    contentHash: "meme-\($0)",
                    note: "表情-\($0)",
                    categoryID: category.id,
                    sortOrder: $0
                )
            }
        )
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 50)

        snapshot.memes[25].note = "只修改这一条"
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedMemes, 0)

        snapshot.memes.removeLast()
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedMemes, 1)
    }

    func testMemeRepositoryPagesWithoutDuplicatesAndPreservesExactSearch() throws {
        let repository = MemeRepository(rootURL: tempRoot("meme-pages"))
        let category = MemeCategory(name: "分页")
        let other = MemeCategory(name: "其他")
        let memes = (0..<31).map { index in
            MemeItem(
                fileName: "\(index).png",
                contentHash: "page-\(index)",
                note: index.isMultiple(of: 3) ? "前缀 Java 中段 Script \(index)" : "普通 \(index)",
                categoryID: index.isMultiple(of: 2) ? category.id : other.id,
                sortOrder: index / 4,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        try repository.save(MemeSnapshot(categories: [category, other], memes: memes))

        var cursor: MemePageCursor?
        var loaded: [MemeItem] = []
        repeat {
            let page = try repository.loadPage(
                categoryID: category.id,
                after: cursor,
                limit: 5
            )
            loaded.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil

        let expected = MemeFilter.apply(memes, categoryID: category.id, query: "")
        XCTAssertEqual(loaded.map(\.id), expected.map(\.id))
        XCTAssertEqual(Set(loaded.map(\.id)).count, loaded.count)
        XCTAssertEqual(try repository.memeCount(categoryID: category.id), expected.count)

        let fuzzy = try repository.loadPage(query: "jav%script", limit: 100)
        XCTAssertEqual(
            fuzzy.items.map(\.id),
            MemeFilter.apply(memes, categoryID: nil, query: "jav%script").map(\.id)
        )
        XCTAssertNil(fuzzy.nextCursor)
        XCTAssertEqual(
            try repository.memeCount(query: "jav%script"),
            fuzzy.items.count
        )
    }

    func testMemeStoreCommonEditsUseSingleRowDeltas() throws {
        let repository = MemeRepository(rootURL: tempRoot("meme-store-deltas"))
        let store = MemeStore(repository: repository)
        let categoryID = try XCTUnwrap(store.addCategory(name: "常用"))
        store.flushPendingSave()
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 0)

        XCTAssertTrue(
            store.addImage(
                Fixture.solidImage(0.4, size: 8),
                categoryID: categoryID,
                note: "初始备注"
            )
        )
        store.flushPendingSave()
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 1)

        let memeID = try XCTUnwrap(store.memes.first?.id)
        store.updateNote(id: memeID, note: "修改后")
        store.flushPendingSave()
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedCategories, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedMemes, 1)
        XCTAssertEqual(
            MemeStore(repository: MemeRepository(rootURL: repository.rootURL))
                .memes.first?.note,
            "修改后"
        )
    }

    func testDuplicateMemeImageIsRejected() {
        let store = makeMemeStore()
        let image = Fixture.solidImage(0.3, size: 7)
        XCTAssertTrue(store.addImage(image, note: "原图"))
        XCTAssertFalse(store.addImage(image, note: "重复"), "identical bytes must not be stored twice")
        XCTAssertEqual(store.filteredMemes(query: "").count, 1)
    }

    func testGIFPayloadKeepsItsFormat() {
        let store = makeMemeStore()
        let payload = ImageAssetData(data: Fixture.gifBytes, fileExtension: "png")
        XCTAssertEqual(payload.fileExtension, "gif", "GIF magic bytes override the suggested extension")
        XCTAssertTrue(store.addImageData(payload, note: "动态"))
        let gif = store.filteredMemes(query: "动态").first!
        XCTAssertTrue(gif.fileName.hasSuffix(".gif"))
        XCTAssertEqual(try? Data(contentsOf: store.imageURL(for: gif)), Fixture.gifBytes)
    }

    func testImageValidationUsesEncodedContainerWithoutChangingGIFBytes() {
        XCTAssertTrue(ImageAssetData.isValidImageData(Fixture.gifBytes))
        XCTAssertFalse(ImageAssetData.isValidImageData(Data("not an image".utf8)))
        let payload = ImageAssetData(data: Fixture.gifBytes, fileExtension: "png")
        XCTAssertEqual(payload.fileExtension, "gif")
        XCTAssertEqual(payload.data, Fixture.gifBytes)
    }

    func testRepositoryAcceptsPrecomputedImageHash() throws {
        let repository = MemeRepository(rootURL: tempRoot("precomputed-hash"))
        let stored = try repository.saveImageData(
            Fixture.gifBytes,
            fileExtension: "gif",
            precomputedContentHash: "already-computed"
        )
        XCTAssertEqual(stored.contentHash, "already-computed")
        XCTAssertEqual(
            try Data(contentsOf: repository.imagesURL.appendingPathComponent(stored.fileName)),
            Fixture.gifBytes
        )
    }

    func testMemeCaptureServiceConsumesClipboardImages() {
        let pasteboard = NSPasteboard.withUniqueName()
        let payload = ImageAssetData(data: Fixture.gifBytes, fileExtension: "gif")
        var captured: ImageAssetData?
        let service = ClipboardCaptureService(pasteboard: pasteboard) { captured = $0 }
        service.start()
        defer { service.stop() }

        XCTAssertTrue(payload.write(to: pasteboard))
        service.inspectPasteboard()

        XCTAssertEqual(captured?.data, Fixture.gifBytes)
        XCTAssertEqual(captured?.fileExtension, "gif")
    }

    func testBundledSampleMemesLoadSeedInOrderAndDedup() throws {
        // Repo root is three levels up from Tests/HedgeMemoCoreTests/<thisFile>.
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HedgeMemo/Resources")
        // Samples may be provided in any common format, matching the seeder.
        let extensions = ["png", "jpg", "jpeg", "gif"]
        let urls = try ["DefaultMeme1", "DefaultMeme2", "DefaultMeme3"].map { name -> URL in
            let url = extensions
                .map { resources.appendingPathComponent("\(name).\($0)") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            return try XCTUnwrap(url, "\(name).* must be present to bundle")
        }

        let store = makeMemeStore()
        for url in urls {
            let payload = try XCTUnwrap(ImageAssetData(fileURL: url))
            XCTAssertTrue(store.addImageData(payload))
        }
        XCTAssertEqual(store.filteredMemes(query: "").count, 3, "all three samples seed")

        // Re-seeding the identical files must not duplicate them.
        for url in urls {
            let payload = try XCTUnwrap(ImageAssetData(fileURL: url))
            XCTAssertFalse(store.addImageData(payload))
        }
        XCTAssertEqual(store.filteredMemes(query: "").count, 3)
    }

    func testArchiveImportPublishesAndPersistsOneDeduplicatedBatch() throws {
        let repository = MemeRepository(rootURL: tempRoot("archive-target"))
        let store = MemeStore(repository: repository)
        let imagesURL = tempRoot("archive-images")
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)

        let png = try XCTUnwrap(Fixture.solidImage(0.6, size: 9).pngData)
        try Fixture.gifBytes.write(to: imagesURL.appendingPathComponent("first.gif"))
        try Fixture.gifBytes.write(to: imagesURL.appendingPathComponent("duplicate.gif"))
        try png.write(to: imagesURL.appendingPathComponent("second.png"))

        let category = MemeCategory(name: "归档分类")
        let snapshot = MemeSnapshot(
            categories: [category],
            memes: [
                MemeItem(fileName: "first.gif", contentHash: "stale-a", note: "一", categoryID: category.id),
                MemeItem(fileName: "duplicate.gif", contentHash: "stale-b", note: "重复", categoryID: category.id),
                MemeItem(fileName: "second.png", contentHash: "stale-c", note: "二", categoryID: category.id),
            ]
        )
        store.importArchive(
            MemeArchiveManifest(memeSnapshot: snapshot, clipboardSnapshot: nil),
            imagesURL: imagesURL
        )

        XCTAssertEqual(store.categories.map(\.name), ["归档分类"])
        XCTAssertEqual(store.filteredMemes(query: "").map(\.note), ["一", "二"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: repository.imagesURL.path).count,
            2,
            "duplicate archive bytes must never create a temporary third file"
        )

        let reloaded = MemeStore(repository: repository)
        XCTAssertEqual(reloaded.filteredMemes(query: "").map(\.note), ["一", "二"])
    }

    func testStreamingMemeArchiveImportPublishesOnePersistedBatch() throws {
        let repository = MemeRepository(rootURL: tempRoot("stream-archive-target"))
        let store = MemeStore(repository: repository)
        let imagesURL = tempRoot("stream-archive-images")
        try FileManager.default.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )
        let png = try XCTUnwrap(Fixture.solidImage(0.4, size: 10).pngData)
        try Fixture.gifBytes.write(to: imagesURL.appendingPathComponent("first.gif"))
        try png.write(to: imagesURL.appendingPathComponent("second.png"))
        let category = MemeCategory(name: "逐条分类")
        let records = [
            MemeItem(
                fileName: "first.gif",
                contentHash: "stale-first",
                note: "逐条一",
                categoryID: category.id
            ),
            MemeItem(
                fileName: "second.png",
                contentHash: "stale-second",
                note: "逐条二",
                categoryID: category.id
            ),
        ]

        try store.importArchive(
            categories: [category],
            imagesURL: imagesURL
        ) { consume in
            for record in records { try consume(record) }
        }

        let reloaded = MemeStore(
            repository: MemeRepository(rootURL: repository.rootURL)
        )
        XCTAssertEqual(reloaded.categories.map(\.name), ["逐条分类"])
        XCTAssertEqual(reloaded.filteredMemes(query: "").map(\.note), ["逐条一", "逐条二"])
        XCTAssertEqual(repository.completedSnapshotWriteCount, 1)
    }

    func testStreamingMemeArchiveFailureRemovesStagedImagesBeforePublishing() throws {
        enum ImportFailure: Error { case truncated }

        let repository = MemeRepository(rootURL: tempRoot("stream-archive-rollback"))
        let store = MemeStore(repository: repository)
        let imagesURL = tempRoot("stream-archive-rollback-images")
        try FileManager.default.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )
        try Fixture.gifBytes.write(
            to: imagesURL.appendingPathComponent("first.gif")
        )
        let record = MemeItem(
            fileName: "first.gif",
            contentHash: "stale-first",
            note: "不应发布"
        )

        XCTAssertThrowsError(
            try store.importArchive(categories: [], imagesURL: imagesURL) {
                consume in
                try consume(record)
                throw ImportFailure.truncated
            }
        )
        XCTAssertTrue(store.filteredMemes(query: "").isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: repository.imagesURL.path
            ),
            []
        )
    }

    func testCopyingAMemeNotifiesSoItStaysOutOfHistory() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.5, size: 8), note: "图"))
        let meme = store.filteredMemes(query: "")[0]
        var notified = false
        store.onDidCopyToPasteboard = { notified = true }
        // A throwaway pasteboard keeps the test off the real system clipboard.
        store.copyToPasteboard(meme, to: NSPasteboard.withUniqueName())
        XCTAssertTrue(notified, "a meme copy must notify so the app can suppress recapture")
    }

    func testSuppressingTheCurrentPasteboardChangeIsIdempotentAndSafe() {
        // The suppression entry point exists for meme clicks; it must run without
        // touching entries and reflect the current system change count.
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("原始"))
        let before = store.entries
        store.suppressCurrentPasteboardChange()
        XCTAssertEqual(store.entries, before, "suppression must not add or remove history entries")
    }

    /// End-to-end: an image the app itself put on the system pasteboard (a meme
    /// click) must not be recaptured into history, while an ordinary image on
    /// the pasteboard still is. Uses the real `.general` pasteboard because the
    /// monitor reads it directly; the written images are tiny.
    func testMemeCopyIsSuppressedWhileOrdinaryImagesAreRecorded() {
        // Control: no suppression wired — the pasteboard image IS captured.
        let control = makeClipboardStore()
        let memeA = makeMemeStore()
        XCTAssertTrue(memeA.addImage(Fixture.solidImage(0.5, size: 8)))
        memeA.copyToPasteboard(memeA.filteredMemes(query: "")[0])
        control.inspectPasteboard()
        XCTAssertEqual(
            control.orderedEntries(key: .builtin(.image)).count, 1,
            "an ordinary image on the pasteboard is captured"
        )

        // Wired exactly as AppServices does: the app's own copy is suppressed.
        let clip = makeClipboardStore()
        let memeB = makeMemeStore()
        memeB.onDidCopyToPasteboard = { [weak clip] in clip?.suppressCurrentPasteboardChange() }
        XCTAssertTrue(memeB.addImage(Fixture.solidImage(0.6, size: 8)))
        memeB.copyToPasteboard(memeB.filteredMemes(query: "")[0])
        clip.inspectPasteboard()
        XCTAssertTrue(
            clip.orderedEntries(key: .builtin(.image)).isEmpty,
            "a meme the app copied must stay out of clipboard history"
        )
    }

    func testMovingAMemeAdoptsTheTargetCategory() {
        let store = makeMemeStore()
        XCTAssertTrue(store.addImage(Fixture.solidImage(0.2, size: 6), note: "图"))
        let id = store.filteredMemes(query: "")[0].id
        let category = store.addCategory(name: "分组")
        XCTAssertNotNil(category)
        store.move(ids: [id], to: category)
        XCTAssertEqual(store.memes.first(where: { $0.id == id })?.categoryID, category)
    }

    // MARK: - ClipboardHistoryStore

    func testConsecutiveDuplicateTextIsNotStoredTwice() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("独立内容"))
        XCTAssertFalse(store.addText("独立内容"), "a repeat of the latest entry merges instead of duplicating")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testNonConsecutiveDuplicateTextMovesExistingEntryForward() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("第一条"))
        let originalID = store.entries.first!.id
        XCTAssertTrue(store.addText("第二条"))

        XCTAssertFalse(store.addText("第一条"), "an existing item is promoted instead of inserted")

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.orderedEntries().map(\.text), ["第一条", "第二条"])
        XCTAssertEqual(store.orderedEntries().first?.id, originalID, "promotion keeps the original item")
        XCTAssertFalse(store.orderedEntries().first?.isPinned == true, "recency promotion is not pinning")
    }

    func testSourceApplicationIdentityPersistsAndUpdatesWhenDuplicateIsRecopied() {
        let root = tempRoot("clip-source-identity")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        let safari = ClipboardSourceApplication(
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari",
            bundleURLPath: "/Applications/Safari.app"
        )
        let notes = ClipboardSourceApplication(
            bundleIdentifier: "com.apple.Notes",
            displayName: "Notes",
            bundleURLPath: "/System/Applications/Notes.app"
        )

        XCTAssertTrue(store.addText("same content", source: safari))
        XCTAssertFalse(store.addText("same content", source: notes))

        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.sourceApp, "Notes")
        XCTAssertEqual(reloaded.entries.first?.sourceBundleIdentifier, "com.apple.Notes")
        XCTAssertEqual(
            reloaded.entries.first?.sourceBundleURLPath,
            "/System/Applications/Notes.app"
        )
    }

    func testTenThousandRepeatedMetadataFieldsShareFiveCanonicalStrings() {
        let store = makeClipboardStore()
        let displayName = "Example Browser Application"
        let bundleIdentifier = "com.example.repeated-browser"
        let bundlePath = "/Applications/Example Browser Application.app"
        let categoryKey = "custom:7B29CB93-63C8-43F1-A8E6-DA1368104B81"
        let formatType = "public.example-rich-text-representation"

        func independentlyDecoded(_ value: String) -> String {
            String(data: Data(value.utf8), encoding: .utf8)!
        }

        let entries = (0..<10_000).map { index in
            var entry = ClipboardEntry(
                kind: .text,
                text: "entry-\(index)",
                contentHash: "source-intern-\(index)",
                sourceApp: independentlyDecoded(displayName),
                sourceBundleIdentifier: independentlyDecoded(bundleIdentifier),
                sourceBundleURLPath: independentlyDecoded(bundlePath),
                manualCategoryStorageValue: independentlyDecoded(categoryKey)
            )
            entry.originalFormats = [
                ClipboardOriginalFormat(
                    typeIdentifier: independentlyDecoded(formatType),
                    fileName: "format-\(index).data",
                    byteCount: index
                )
            ]
            return entry
        }
        store.injectPreviewEntries(entries)

        XCTAssertEqual(store.sourceStringInternerMetrics.uniqueStringCount, 5)
        XCTAssertEqual(
            store.sourceStringInternerMetrics.canonicalizedAssignmentCount,
            50_000
        )
        XCTAssertEqual(store.sourceStringInternerMetrics.peakUniqueStringCount, 5)
        XCTAssertTrue(store.entries.allSatisfy {
            $0.sourceApp == displayName
                && $0.sourceBundleIdentifier == bundleIdentifier
                && $0.sourceBundleURLPath == bundlePath
                && $0.manualCategoryStorageValue == categoryKey
                && $0.originalFormats?.first?.typeIdentifier == formatType
        })

        func utf8Address(_ value: String?) -> UInt? {
            guard let value else { return nil }
            return value.utf8.withContiguousStorageIfAvailable { buffer in
                buffer.baseAddress.map { UInt(bitPattern: $0) }
            } ?? nil
        }

        XCTAssertEqual(
            Set(store.entries.compactMap { utf8Address($0.sourceApp) }).count,
            1
        )
        XCTAssertEqual(
            Set(store.entries.compactMap { utf8Address($0.sourceBundleIdentifier) }).count,
            1
        )
        XCTAssertEqual(
            Set(store.entries.compactMap { utf8Address($0.sourceBundleURLPath) }).count,
            1
        )
        XCTAssertEqual(
            Set(store.entries.compactMap {
                utf8Address($0.manualCategoryStorageValue)
            }).count,
            1
        )
        XCTAssertEqual(
            Set(store.entries.compactMap {
                utf8Address($0.originalFormats?.first?.typeIdentifier)
            }).count,
            1
        )
    }

    func testSourceFilterCachesStayBoundedAndReleaseCompletely() {
        let store = makeClipboardStore()
        store.settings.maxEntries = 10_000
        let entries = (0..<300).map { index in
            ClipboardEntry(
                kind: .text,
                text: "shared source-filter entry \(index)",
                contentHash: "source-filter-\(index)",
                sourceApp: "Application \(index)",
                sourceBundleIdentifier: "com.example.application-\(index)"
            )
        }
        store.injectPreviewEntries(entries)
        let categories = (0..<12).map { index in
            CustomClipboardCategory(
                name: "Source cache \(index)",
                matchMode: .all,
                rules: [
                    ClipboardClassificationRule(
                        kind: .contains,
                        value: "shared source-filter"
                    )
                ]
            )
        }
        store.settings.customCategories = categories

        for category in categories {
            let key = ClipboardCategoryKey.custom(category.id)
            XCTAssertEqual(
                store.sourceApplicationsForFiltering(key: key).count,
                300
            )
            XCTAssertFalse(store.hasUnknownSourceForFiltering(key: key))
        }

        XCTAssertLessThanOrEqual(
            store.sourceApplicationMemoMetrics.entryCount,
            8
        )
        XCTAssertLessThanOrEqual(
            store.sourceApplicationMemoMetrics.retainedApplicationCount,
            2_048
        )
        XCTAssertLessThanOrEqual(
            store.sourceApplicationMemoMetrics.unknownEntryCount,
            8
        )

        store.releaseTransientCaches()
        XCTAssertEqual(store.sourceApplicationMemoMetrics.entryCount, 0)
        XCTAssertEqual(
            store.sourceApplicationMemoMetrics.retainedApplicationCount,
            0
        )
        XCTAssertEqual(store.sourceApplicationMemoMetrics.unknownEntryCount, 0)
    }

    func testPasteboardCaptureHonorsBlocklistAndAllowlistBeforeRecording() {
        let source = ClipboardSourceApplication(
            bundleIdentifier: "com.example.private",
            displayName: "Private App"
        )
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("must be filtered", forType: .string)

        let blocked = makeClipboardStore()
        blocked.settings.appFilterMode = .blocklist
        blocked.settings.appFilterApplications = [source]
        blocked.capturePasteboardContents(pasteboard, source: source)
        XCTAssertTrue(blocked.entries.isEmpty)

        let notAllowed = makeClipboardStore()
        notAllowed.settings.appFilterMode = .allowlist
        notAllowed.settings.appFilterApplications = []
        notAllowed.capturePasteboardContents(pasteboard, source: source)
        XCTAssertTrue(notAllowed.entries.isEmpty)

        let allowed = makeClipboardStore()
        allowed.settings.appFilterMode = .allowlist
        allowed.settings.appFilterApplications = [source]
        allowed.capturePasteboardContents(pasteboard, source: source)
        XCTAssertEqual(allowed.entries.map(\.text), ["must be filtered"])
        XCTAssertEqual(allowed.entries.first?.sourceBundleIdentifier, "com.example.private")
    }

    func testReCopyingPinnedContentPreservesExplicitPinState() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("固定内容"))
        let id = store.entries.first!.id
        store.togglePinned(id: id)
        XCTAssertTrue(store.addText("普通内容"))

        XCTAssertFalse(store.addText("固定内容"))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first(where: { $0.id == id })?.isPinned, true)
    }

    func testNonConsecutiveDuplicateImageReusesTheStoredFile() throws {
        let root = tempRoot("image-dedup")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        let first = ImageAssetData(data: Fixture.solidImage(0.2, size: 8).pngData!, fileExtension: "png")
        let second = ImageAssetData(data: Fixture.solidImage(0.8, size: 8).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(first))
        let originalID = store.entries.first!.id
        let originalFileName = store.entries.first!.imageFileName
        XCTAssertTrue(store.addImageData(second))

        XCTAssertFalse(store.addImageData(first))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.orderedEntries().first?.id, originalID)
        XCTAssertEqual(store.orderedEntries().first?.imageFileName, originalFileName)
        let files = try FileManager.default.contentsOfDirectory(atPath: repository.imagesURL.path)
        XCTAssertEqual(files.count, 2, "duplicate capture must not write a third image file")
    }

    func testLoadingLegacySnapshotCollapsesDuplicatesAndMergesPins() throws {
        let root = tempRoot("legacy-dedup")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let older = ClipboardEntry(
            kind: .text,
            text: "重复",
            contentHash: "same",
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            isPinned: true,
            pinnedOrder: 0
        )
        let newer = ClipboardEntry(
            kind: .text,
            text: "重复",
            contentHash: "same",
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        try repository.save(ClipboardHistorySnapshot(entries: [older, newer]))

        let store = ClipboardHistoryStore(repository: repository)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, newer.id, "the newest record remains canonical")
        XCTAssertEqual(store.entries.first?.isPinned, true, "explicit state from duplicates is preserved")
    }

    func testPinAndDesktopPinAreIndependentAndPersist() {
        let root = tempRoot("clip-persist")
        let store = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertTrue(store.addText("固定状态"))
        let id = store.entries.first!.id

        store.togglePinned(id: id)
        XCTAssertTrue(store.entries.first!.isPinned)
        XCTAssertNotEqual(store.entries.first!.isDesktopPinned, true, "list pinning must not create a desktop note")

        store.toggleDesktopPinned(id: id)
        XCTAssertTrue(store.entries.first!.isPinned, "desktop pinning must not clear list pinning")
        XCTAssertEqual(store.entries.first!.isDesktopPinned, true)

        let reloaded = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertEqual(reloaded.entries.first?.isPinned, true, "list pin state must persist")
        XCTAssertEqual(reloaded.entries.first?.isDesktopPinned, true, "desktop note state must persist independently")
    }

    func testDesktopPinOrderIsFirstComeAndRepinMovesToEnd() {
        let root = tempRoot("desktop-order")
        let store = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertTrue(store.addText("第一条"))
        XCTAssertTrue(store.addText("第二条"))
        let firstID = store.entries.first(where: { $0.text == "第一条" })!.id
        let secondID = store.entries.first(where: { $0.text == "第二条" })!.id

        store.toggleDesktopPinned(id: firstID)
        store.toggleDesktopPinned(id: secondID)
        XCTAssertEqual(ClipboardHistoryPolicy.desktopPinnedEntries(store.entries).map(\.id), [firstID, secondID])

        store.toggleDesktopPinned(id: firstID)
        store.toggleDesktopPinned(id: firstID)
        XCTAssertEqual(ClipboardHistoryPolicy.desktopPinnedEntries(store.entries).map(\.id), [secondID, firstID])

        let reloaded = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertEqual(ClipboardHistoryPolicy.desktopPinnedEntries(reloaded.entries).map(\.id), [secondID, firstID])
    }

    func testScreenshotsStayInTheirDedicatedCategory() {
        let store = makeClipboardStore()
        let payload = ImageAssetData(data: Fixture.solidImage(0.4, size: 10).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot))
        XCTAssertEqual(store.orderedEntries(key: .builtin(.screenshot)).count, 1)
        XCTAssertTrue(store.orderedEntries(key: .builtin(.image)).isEmpty, "screenshots must not mix with copied images")
    }

    func testDisablingACategoryClearsAndBlocksIt() {
        let store = makeClipboardStore()
        let payload = ImageAssetData(data: Fixture.solidImage(0.4, size: 10).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot))
        store.setCategory(.builtin(.screenshot), enabled: false)
        XCTAssertTrue(store.orderedEntries(key: .builtin(.screenshot)).isEmpty, "disabling clears existing records")
        XCTAssertFalse(
            store.addImageData(payload, sourceApp: "HedgeMemo", origin: .hedgeMemoScreenshot),
            "a disabled category records nothing further"
        )
    }

    func testUpdateTextEditsContentAndRecomputesHash() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("原始内容"))
        let id = store.entries.first!.id
        let originalHash = store.entries.first!.contentHash

        store.updateText(id: id, text: "编辑后的内容")

        let edited = store.entries.first!
        XCTAssertEqual(edited.text, "编辑后的内容")
        XCTAssertNotEqual(edited.contentHash, originalHash, "the hash must track the edited text, not the original")
    }

    func testUpdateTextIgnoresImageEntries() {
        let store = makeClipboardStore()
        let payload = ImageAssetData(data: Fixture.solidImage(0.4, size: 10).pngData!, fileExtension: "png")
        XCTAssertTrue(store.addImageData(payload))
        let id = store.entries.first!.id

        store.updateText(id: id, text: "不应生效")

        XCTAssertNil(store.entries.first?.text, "an image entry has no editable text body")
    }

    func testUpdateTextIgnoresUnknownID() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("内容"))
        let before = store.entries

        store.updateText(id: UUID(), text: "不存在的条目")

        XCTAssertEqual(store.entries, before)
    }

    func testUpdateTextPersists() {
        let root = tempRoot("clip-edit-persist")
        let store = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertTrue(store.addText("原始内容"))
        let id = store.entries.first!.id
        store.updateText(id: id, text: "持久化后的内容")

        let reloaded = ClipboardHistoryStore(repository: ClipboardHistoryRepository(rootURL: root))
        XCTAssertEqual(reloaded.entries.first?.text, "持久化后的内容")
    }

    func testBurstSnapshotWritesFlushLatestGenerationInOrder() {
        let root = tempRoot("clip-write-order")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        for index in 0..<40 {
            XCTAssertTrue(store.addText("突发写入-\(index)"))
        }

        store.flushPendingSave()
        let reloaded = ClipboardHistoryStore(
            repository: ClipboardHistoryRepository(rootURL: root)
        )
        XCTAssertEqual(reloaded.entries.count, 40)
        XCTAssertEqual(
            reloaded.entries.compactMap(\.text),
            (0..<40).map { "突发写入-\($0)" },
            "the final queued generation must contain every mutation in source order"
        )
    }

    func testClipboardArchiveBatchWritesOneSnapshot() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("clip-import-coalescing"))
        let store = ClipboardHistoryStore(repository: repository)
        let imported = (0..<40).map {
            ClipboardEntry(kind: .text, text: "归档-\($0)", contentHash: "stale-\($0)")
        }
        let emptyAssets = tempRoot("clip-import-empty-assets")
        try FileManager.default.createDirectory(at: emptyAssets, withIntermediateDirectories: true)

        try store.importArchive(
            ClipboardHistorySnapshot(entries: imported),
            imagesURL: emptyAssets,
            originalFormatsURL: emptyAssets
        )
        store.flushPendingSave()

        XCTAssertEqual(repository.completedSnapshotWriteCount, 1)
        XCTAssertEqual(store.entries.count, 40)
        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.compactMap(\.text), imported.compactMap(\.text))
    }

    func testManualCategoryMovesEntryPersistsAndCanReturnToAutomatic() {
        let root = tempRoot("clip-manual-category")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(store.addText("let value = 1"))
        let id = store.entries.first!.id

        XCTAssertTrue(store.setManualCategory(id: id, key: .builtin(.text)))
        XCTAssertTrue(store.orderedEntries(key: .builtin(.code)).isEmpty)
        XCTAssertEqual(store.orderedEntries(key: .builtin(.text)).map(\.id), [id])

        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.first?.manualCategoryKey, .builtin(.text))
        XCTAssertTrue(reloaded.setManualCategory(id: id, key: nil))
        XCTAssertEqual(reloaded.orderedEntries(key: .builtin(.code)).map(\.id), [id])
    }

    func testManualCategoryStoreRejectsIncompatibleTarget() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("普通文字"))
        let id = store.entries.first!.id

        XCTAssertFalse(store.setManualCategory(id: id, key: .builtin(.image)))
        XCTAssertNil(store.entries.first?.manualCategoryKey)
    }

    func testManualCategoryAppearsAfterTargetResultWasMemoized() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("let cached = true\nprint(cached)"))
        let id = store.entries.first!.id
        XCTAssertTrue(store.orderedEntries(key: .builtin(.text)).isEmpty)

        XCTAssertTrue(store.setManualCategory(id: id, key: .builtin(.text)))

        XCTAssertEqual(store.orderedEntries(key: .builtin(.text)).map(\.id), [id])
    }

    func testManualPasswordCategoryEncryptsAtRestAndCanMoveBackToText() throws {
        let root = tempRoot("clip-manual-password")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let store = ClipboardHistoryStore(repository: repository)
        store.setCategory(.builtin(.password), enabled: true)
        XCTAssertTrue(store.addText("manual secret"))
        let id = store.entries.first!.id

        XCTAssertTrue(store.setManualCategory(id: id, key: .builtin(.password)))
        let protected = try XCTUnwrap(store.entries.first)
        XCTAssertTrue(protected.isSecret)
        XCTAssertTrue(SecretVault.isEncrypted(try XCTUnwrap(protected.text)))
        XCTAssertNotEqual(protected.text, "manual secret")
        XCTAssertEqual(store.orderedEntries(key: .builtin(.password)).map(\.id), [id])
        XCTAssertTrue(store.orderedEntries(key: .builtin(.text)).isEmpty)

        let reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(reloaded.setManualCategory(id: id, key: .builtin(.text)))
        let restored = try XCTUnwrap(reloaded.entries.first)
        XCTAssertFalse(restored.isSecret)
        XCTAssertEqual(restored.text, "manual secret")
        XCTAssertEqual(reloaded.orderedEntries(key: .builtin(.text)).map(\.id), [id])
        XCTAssertTrue(reloaded.orderedEntries(key: .builtin(.password)).isEmpty)
    }

    func testSeedEntriesAppendInGivenOrderNewestFirst() {
        let store = makeClipboardStore()
        let now = Date()
        let lines = ["第一条", "第二条", "第三条"]
        let seeds = lines.enumerated().map { index, line in
            ClipboardEntry(
                kind: .text,
                text: line,
                contentHash: "seed\(index)",
                createdAt: now.addingTimeInterval(-Double(index))
            )
        }
        store.addSeedEntries(seeds)
        // Index 0 has the latest timestamp, so it sorts to the top.
        XCTAssertEqual(store.orderedEntries().compactMap(\.text), lines)
    }

    func testEmptySeedIsANoOp() {
        let store = makeClipboardStore()
        store.addSeedEntries([])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRepositoriesReportPersistenceOnlyAfterFirstWrite() {
        let clipRepo = ClipboardHistoryRepository(rootURL: tempRoot("clip-flag"))
        XCTAssertFalse(clipRepo.hasPersistedHistory, "a fresh install has no snapshot yet")
        let clipStore = ClipboardHistoryStore(repository: clipRepo)
        XCTAssertFalse(clipRepo.hasPersistedHistory, "loading an empty store must not write a snapshot")
        XCTAssertTrue(clipStore.addText("首次内容"))
        XCTAssertTrue(clipRepo.hasPersistedHistory, "the first write marks the store as used")

        let memeRepo = MemeRepository(rootURL: tempRoot("meme-flag"))
        XCTAssertFalse(memeRepo.hasPersistedLibrary)
        let memeStore = MemeStore(repository: memeRepo)
        XCTAssertFalse(memeRepo.hasPersistedLibrary)
        XCTAssertTrue(memeStore.addImage(Fixture.solidImage(0.3, size: 6), note: "图"))
        XCTAssertTrue(memeRepo.hasPersistedLibrary)
    }

    func testLegacyClipboardJSONMigratesToSQLiteAndRemainsAsBackup() throws {
        let root = tempRoot("clip-sqlite-migration")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("clipboard-history.json")
        let original = ClipboardHistorySnapshot(entries: [
            ClipboardEntry(kind: .text, text: "旧数据", contentHash: "legacy")
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original).write(to: legacyURL, options: .atomic)
        // Simulate termination after the SQLite file was created but before
        // the migration transaction committed its initialization marker.
        try Data().write(to: root.appendingPathComponent("clipboard-history.sqlite3"))

        let repository = ClipboardHistoryRepository(rootURL: root)
        let migrated = try repository.load()
        XCTAssertEqual(migrated.entries.compactMap(\.text), ["旧数据"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.databaseURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyURL.path),
            "the source JSON remains available as a migration backup"
        )

        // Once migration succeeds, SQLite is canonical even if the old backup
        // later contains a different snapshot.
        try encoder.encode(ClipboardHistorySnapshot()).write(to: legacyURL, options: .atomic)
        let reloaded = try ClipboardHistoryRepository(rootURL: root).load()
        XCTAssertEqual(reloaded.entries.compactMap(\.text), ["旧数据"])
    }

    func testClipboardSQLiteSaveMutatesOnlyChangedRows() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("clip-sqlite-delta"))
        let entries = (0..<100).map {
            ClipboardEntry(kind: .text, text: "条目-\($0)", contentHash: "hash-\($0)")
        }
        var snapshot = ClipboardHistorySnapshot(entries: entries)
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 100)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)

        snapshot.entries[50].isPinned = true
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)

        snapshot.entries.removeFirst()
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 1)

        snapshot.settings.autoPaste.toggle()
        try repository.save(snapshot)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)
    }

    func testClipboardCaptureUsesSingleRowDeltaAndTrimsSingleRowAtLimit() throws {
        let root = tempRoot("clip-sqlite-capture-delta")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let initialEntries = (0..<100).map {
            ClipboardEntry(kind: .text, text: "已有-\($0)", contentHash: "existing-\($0)")
        }
        try repository.save(ClipboardHistorySnapshot(entries: initialEntries))
        let store = ClipboardHistoryStore(repository: repository)

        XCTAssertTrue(store.addText("最新捕获"))
        store.flushPendingSave()

        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 1)
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertFalse(store.entries.contains { $0.id == initialEntries[0].id })
        XCTAssertEqual(
            ClipboardHistoryStore(
                repository: ClipboardHistoryRepository(rootURL: root)
            ).entries.compactMap(\.text).last,
            "最新捕获"
        )
    }

    func testClipboardUsageAndOrdinarySettingsAvoidFullSnapshotDiff() throws {
        let repository = ClipboardHistoryRepository(rootURL: tempRoot("clip-sqlite-hot-deltas"))
        let store = ClipboardHistoryStore(repository: repository)
        XCTAssertTrue(store.addText("经常使用"))
        store.flushPendingSave()
        let entry = try XCTUnwrap(store.entries.first)

        XCTAssertTrue(store.copyToPasteboard(entry, to: NSPasteboard.withUniqueName()))
        store.flushPendingSave()
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 1)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)

        store.settings.itemSize = .compact
        store.flushPendingSave()
        XCTAssertEqual(repository.lastDatabaseMutationCounts.changedEntries, 0)
        XCTAssertEqual(repository.lastDatabaseMutationCounts.deletedEntries, 0)
        XCTAssertEqual(
            ClipboardHistoryStore(
                repository: ClipboardHistoryRepository(rootURL: repository.rootURL)
            ).settings.itemSize,
            .compact
        )
    }

    func testDeleteAndClearHistory() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("甲"))
        XCTAssertTrue(store.addText("乙"))
        let firstID = store.entries.first!.id
        store.delete(id: firstID)
        XCTAssertFalse(store.entries.contains { $0.id == firstID })
        store.clearHistory()
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// Category filtering is cached independently of the search query so that
    /// typing does not re-classify the history. Every mutation that can change
    /// what a category contains must therefore drop that cache.
    func testCategoryResultsRefreshAfterEveryMutation() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("普通中文内容"))
        XCTAssertTrue(store.addText("另一段普通内容"))
        // Prime the caches for both an unfiltered and a searched view.
        XCTAssertEqual(store.orderedEntries(key: .builtin(.text)).count, 2)
        XCTAssertEqual(store.orderedEntries(query: "另一段", key: .builtin(.text)).count, 1)
        XCTAssertTrue(store.orderedEntries(key: .builtin(.code)).isEmpty)

        XCTAssertTrue(store.addText("let answer = 42;"))
        XCTAssertEqual(
            store.orderedEntries(key: .builtin(.code)).compactMap(\.text),
            ["let answer = 42;"],
            "a new entry must appear in an already-consulted category"
        )
        XCTAssertEqual(store.orderedEntries(key: .builtin(.text)).count, 2)

        let id = store.orderedEntries(key: .builtin(.text)).first!.id
        store.updateText(id: id, text: "另一段普通内容 已编辑")
        XCTAssertEqual(store.orderedEntries(query: "已编辑", key: .builtin(.text)).count, 1)

        store.delete(id: id)
        XCTAssertEqual(store.orderedEntries(key: .builtin(.text)).count, 1)
        XCTAssertTrue(store.orderedEntries(query: "已编辑", key: .builtin(.text)).isEmpty)

        // Releasing presentation caches must not change what the store reports.
        store.releaseTransientCaches()
        XCTAssertEqual(store.orderedEntries(key: .builtin(.text)).count, 1)
        XCTAssertEqual(store.orderedEntries(key: .builtin(.code)).count, 1)
    }

    /// Typing narrows the previous result instead of rescanning the category.
    /// Every step must still produce exactly what a full pass would.
    func testIncrementalSearchMatchesAFullPassAtEveryStep() {
        let store = makeClipboardStore()
        let texts = [
            "invoice 2026 approved",
            "invoice 2025 pending",
            "在发票 invoice 上签字",
            "无关的普通内容",
            "INVOICE-2026-FINAL",
        ]
        for text in texts { XCTAssertTrue(store.addText(text)) }

        func expectedResult(_ query: String) -> [UUID] {
            ClipboardHistoryPolicy.ordered(
                store.entries,
                query: query,
                key: .builtin(.text)
            ).map(\.id)
        }
        func assertMatchesFullPass(_ query: String, _ message: String = "") {
            XCTAssertEqual(
                store.orderedEntries(query: query, key: .builtin(.text)).map(\.id),
                expectedResult(query),
                message.isEmpty ? "query \(query)" : message
            )
        }

        // Typing forward, the case the chain is built for.
        for length in 1..."invoice 2026".count {
            assertMatchesFullPass(String("invoice 2026".prefix(length)))
        }
        // Backspacing widens the result again, which the chain cannot reuse.
        for length in stride(from: "invoice 2026".count, through: 1, by: -1) {
            assertMatchesFullPass(String("invoice 2026".prefix(length)))
        }
        // Wildcards match through a different comparison, so a plain query must
        // never be narrowed into a wildcard one or the reverse.
        assertMatchesFullPass("invoice")
        assertMatchesFullPass("invoice%2026")
        assertMatchesFullPass("invoice%2026%final")
        assertMatchesFullPass("invoice")
        assertMatchesFullPass("")
        assertMatchesFullPass("%")
        assertMatchesFullPass("%invoice")
        assertMatchesFullPass("在发票")

        // A new entry must reach an already-narrowed query.
        XCTAssertTrue(store.addText("invoice 2026 追加"))
        assertMatchesFullPass("invoice 2026", "a capture during a search must appear")
    }

    /// The panel observes this counter instead of comparing history snapshots.
    func testEntriesRevisionAdvancesOnEveryChange() {
        let store = makeClipboardStore()
        let start = store.entriesRevision
        XCTAssertTrue(store.addText("甲"))
        let afterAdd = store.entriesRevision
        XCTAssertGreaterThan(afterAdd, start)

        store.togglePinned(id: store.entries.first!.id)
        XCTAssertGreaterThan(store.entriesRevision, afterAdd)

        let afterPin = store.entriesRevision
        XCTAssertFalse(store.addText("甲"), "a duplicate is promoted rather than added")
        XCTAssertGreaterThan(store.entriesRevision, afterPin, "promotion still changes the list")
    }

    func testClearHistoryCanTargetSelectedCategories() {
        let store = makeClipboardStore()
        XCTAssertTrue(store.addText("普通中文内容"))
        XCTAssertTrue(store.addText("let answer = 42;"))
        XCTAssertTrue(store.addText("https://example.com/path"))

        let selected: Set<ClipboardCategoryKey> = [.builtin(.code), .builtin(.link)]
        XCTAssertEqual(store.entryCount(matching: selected), 2)
        store.clearHistory(matching: selected)

        XCTAssertEqual(store.entries.compactMap(\.text), ["普通中文内容"])
    }

    func testConfiguredMaximumHistoryKeepsExactSearchAndBoundedFirstPage() {
        let store = makeClipboardStore()
        let textKey = ClipboardCategoryKey.builtin(.text).storageValue
        let entries = (0..<10_000).map { index in
            ClipboardEntry(
                kind: .text,
                text: index == 9_999 ? "needle middle 9999 tail" : "普通历史条目 \(index)",
                contentHash: "large-fixture-\(index)",
                manualCategoryStorageValue: textKey
            )
        }
        store.injectPreviewEntries(entries)

        let all = store.orderedEntries(key: .builtin(.text))
        XCTAssertEqual(all.count, 10_000)
        XCTAssertEqual(
            all.retainedPositionCount,
            10_000,
            "the result retains indexes only, never a second 10,000-entry model array"
        )
        XCTAssertEqual(
            store.orderedEntries(query: "needle%9999", key: .builtin(.text)).compactMap(\.text),
            ["needle middle 9999 tail"],
            "large-library optimization must preserve ordered-fragment search semantics"
        )
        XCTAssertEqual(
            Array(all.prefix(ClipboardPanelPagination.initialLimit(for: .builtin(.text)))).count,
            300,
            "the visible page remains bounded even at the configured history ceiling"
        )

        for index in 0..<40 {
            _ = store.orderedEntries(
                query: "missing-query-\(index)",
                key: .builtin(.text)
            )
        }
        XCTAssertLessThanOrEqual(store.orderedMemoMetrics.entryCount, 8)
        XCTAssertLessThanOrEqual(
            store.orderedMemoMetrics.retainedPositionCount,
            100_000
        )
        store.releaseTransientCaches()
        XCTAssertEqual(store.orderedMemoMetrics.entryCount, 0)
        XCTAssertEqual(store.orderedMemoMetrics.retainedPositionCount, 0)
    }

    func testClipboardOrderedResultsMapDesktopPinsAndSecretsLazily() {
        let ordinary = (0..<20).map { index in
            ClipboardEntry(
                kind: .text,
                text: "ordinary-\(index)",
                contentHash: "ordinary-\(index)"
            )
        }
        let firstDesktop = ClipboardEntry(
            kind: .text,
            text: "desktop-0",
            contentHash: "desktop-0"
        )
        let secondDesktop = ClipboardEntry(
            kind: .text,
            text: "desktop-1",
            contentHash: "desktop-1"
        )
        let secret = ClipboardEntry(
            kind: .text,
            text: "encrypted-envelope",
            contentHash: "secret",
            origin: .concealedPassword
        )
        let source = ordinary + [firstDesktop, secondDesktop, secret]
        let results = ClipboardOrderedResults(
            source: source,
            ordinaryPositions: Array(ordinary.indices) + [22],
            desktopPinnedPositions: [20, 21]
        ).displayingSecrets([secret.id: "revealed"])

        XCTAssertEqual(results.count, 23)
        XCTAssertEqual(results.retainedPositionCount, 23)
        XCTAssertEqual(
            results[ClipboardHistoryPolicy.desktopPinnedInsertionIndex].id,
            firstDesktop.id
        )
        XCTAssertEqual(
            results[ClipboardHistoryPolicy.desktopPinnedInsertionIndex + 1].id,
            secondDesktop.id
        )
        XCTAssertEqual(results.last?.text, "revealed")
        XCTAssertEqual(source.last?.text, "encrypted-envelope")
    }
}
