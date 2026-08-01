import Foundation
import SQLite3

final class MemeDatabase: @unchecked Sendable {
    struct MutationCounts: Equatable {
        let changedCategories: Int
        let deletedCategories: Int
        let changedMemes: Int
        let deletedMemes: Int
    }

    private let url: URL
    private let textReaderLock = NSLock()
    private var textReaderConnection: SQLiteConnection?
    #if DEBUG
    private(set) var textReaderConnectionOpenCount = 0
    #endif
    private(set) var lastBackfillRowCount = 0
    private(set) var lastBackfillPeakResidentRowCount = 0

    init(url: URL) {
        self.url = url
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var isInitialized: Bool {
        get throws {
            guard exists else { return false }
            let connection = try SQLiteConnection(url: url)
            try prepareSchema(connection)
            let statement = try connection.prepare(
                "SELECT 1 FROM storage_metadata WHERE key = 'initialized' LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func load(
        textProvider: MemeTextProvider? = nil
    ) throws -> MemeSnapshot {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        lastBackfillRowCount = 0
        lastBackfillPeakResidentRowCount = 0

        var categories: [MemeCategory] = []
        let categoryStatement = try connection.prepare(
            "SELECT payload FROM meme_categories ORDER BY position ASC"
        )
        defer { sqlite3_finalize(categoryStatement) }
        while sqlite3_step(categoryStatement) == SQLITE_ROW {
            let data = try rowData(statement: categoryStatement, column: 0)
            let category = try Self.decoder.decode(MemeCategory.self, from: data)
            categories.append(category)
        }

        var memes: [MemeItem] = []
        let needsBackfill = try hasMissingHeader(
            table: "meme_items",
            connection: connection
        )
        let stageBackfill: OpaquePointer?
        if needsBackfill {
            try connection.execute(
                """
                CREATE TEMP TABLE meme_body_backfill (
                    id TEXT PRIMARY KEY NOT NULL,
                    header_payload BLOB NOT NULL,
                    note_body TEXT NOT NULL,
                    ocr_body TEXT NOT NULL
                )
                """
            )
            stageBackfill = try connection.prepare(
                """
                INSERT INTO meme_body_backfill (
                    id, header_payload, note_body, ocr_body
                ) VALUES (?, ?, ?, ?)
                """
            )
        } else {
            stageBackfill = nil
        }
        defer {
            if let stageBackfill { sqlite3_finalize(stageBackfill) }
        }
        let memeStatement = try connection.prepare(
            """
            SELECT header_payload, payload
            FROM meme_items
            ORDER BY position ASC
            """
        )
        defer { sqlite3_finalize(memeStatement) }
        if needsBackfill {
            try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        }
        do {
            while sqlite3_step(memeStatement) == SQLITE_ROW {
                let hasHeader = sqlite3_column_type(memeStatement, 0) != SQLITE_NULL
                let payloadColumn: Int32 = hasHeader ? 0 : 1
                let data = try rowData(
                    statement: memeStatement,
                    column: payloadColumn
                )
                var meme = try Self.decoder.decode(MemeItem.self, from: data)
                if !hasHeader, let stageBackfill {
                    lastBackfillRowCount += 1
                    lastBackfillPeakResidentRowCount = 1
                    sqlite3_reset(stageBackfill)
                    sqlite3_clear_bindings(stageBackfill)
                    try connection.bind(meme.id.uuidString, to: 1, in: stageBackfill)
                    try connection.bind(
                        try Self.encoder.encode(meme.metadataProjection),
                        to: 2,
                        in: stageBackfill
                    )
                    try connection.bind(meme.note, to: 3, in: stageBackfill)
                    try connection.bind(meme.ocrText, to: 4, in: stageBackfill)
                    try connection.stepDone(stageBackfill)
                }
                if let textProvider { meme.deferText(to: textProvider) }
                memes.append(meme)
            }
            guard sqlite3_errcode(connection.handle) == SQLITE_OK
                    || sqlite3_errcode(connection.handle) == SQLITE_DONE else {
                throw ClipboardHistoryDatabaseError.execute(
                    connection.errorMessage
                )
            }
            if needsBackfill {
                try applyStagedBodyBackfill(connection: connection)
                try connection.execute("COMMIT")
            }
        } catch {
            if needsBackfill { try? connection.execute("ROLLBACK") }
            throw error
        }

        return MemeSnapshot(categories: categories, memes: memes)
    }

    func loadText(id: UUID) -> MemeTextBody? {
        textReaderLock.lock()
        defer { textReaderLock.unlock() }
        do {
            let connection = try textReaderConnectionLocked()
            let statement = try connection.prepare(
                """
                SELECT note_body, ocr_body, payload
                FROM meme_items
                WHERE id = ?
                LIMIT 1
                """
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(id.uuidString, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(statement, 0) != SQLITE_NULL,
               sqlite3_column_type(statement, 1) != SQLITE_NULL {
                return MemeTextBody(
                    note: Self.rowString(statement: statement, column: 0),
                    ocrText: Self.rowString(statement: statement, column: 1)
                )
            }
            let item = try Self.decoder.decode(
                MemeItem.self,
                from: try rowData(statement: statement, column: 2)
            )
            return MemeTextBody(note: item.note, ocrText: item.ocrText)
        } catch {
            return nil
        }
    }

    /// Opens and configures the reader before a write transaction without
    /// fetching (and immediately discarding) one potentially large body.
    private func prepareTextReaderConnection() {
        textReaderLock.lock()
        defer { textReaderLock.unlock() }
        _ = try? textReaderConnectionLocked()
    }

    /// Caller must hold `textReaderLock`.
    private func textReaderConnectionLocked() throws -> SQLiteConnection {
        if let existing = textReaderConnection { return existing }
        let created = try SQLiteConnection(url: url)
        try prepareSchema(created)
        textReaderConnection = created
        #if DEBUG
        textReaderConnectionOpenCount += 1
        #endif
        return created
    }

    func releaseTextReaderConnection() {
        textReaderLock.withLock {
            textReaderConnection = nil
        }
    }

    var hasTextReaderConnection: Bool {
        textReaderLock.withLock { textReaderConnection != nil }
    }

    private func applyStagedBodyBackfill(
        connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            UPDATE meme_items
            SET header_payload = (
                    SELECT header_payload
                    FROM meme_body_backfill
                    WHERE meme_body_backfill.id = meme_items.id
                ),
                note_body = (
                    SELECT note_body
                    FROM meme_body_backfill
                    WHERE meme_body_backfill.id = meme_items.id
                ),
                ocr_body = (
                    SELECT ocr_body
                    FROM meme_body_backfill
                    WHERE meme_body_backfill.id = meme_items.id
                )
            WHERE id IN (SELECT id FROM meme_body_backfill)
            """
        )
    }

    /// Reads at most one presentation page while scanning matching rows
    /// directly from SQLite. Search remains byte-for-byte compatible with the
    /// in-memory matcher, including the implicitly unanchored `%` semantics.
    func loadPage(
        categoryID: UUID?,
        query: String,
        after cursor: MemePageCursor?,
        limit: Int
    ) throws -> MemePage {
        guard limit > 0 else { return MemePage(items: [], nextCursor: cursor) }
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        let matcher = PercentFuzzyMatcher(query: query)
        var predicates: [String] = []
        if categoryID != nil {
            predicates.append("category_id = ?")
        }
        if cursor != nil {
            predicates.append(
                """
                (sort_order > ? OR
                 (sort_order = ? AND created_at > ?) OR
                 (sort_order = ? AND created_at = ? AND id > ?))
                """
            )
        }
        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        let statement = try connection.prepare(
            """
            SELECT payload, sort_order, created_at, id
            FROM meme_items
            \(whereClause)
            ORDER BY sort_order ASC, created_at ASC, id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var binding: Int32 = 1
        if let categoryID {
            try connection.bind(categoryID.uuidString, to: binding, in: statement)
            binding += 1
        }
        if let cursor {
            try connection.bind(cursor.sortOrder, to: binding, in: statement)
            try connection.bind(cursor.sortOrder, to: binding + 1, in: statement)
            try connection.bind(cursor.createdAt, to: binding + 2, in: statement)
            try connection.bind(cursor.sortOrder, to: binding + 3, in: statement)
            try connection.bind(cursor.createdAt, to: binding + 4, in: statement)
            try connection.bind(cursor.id, to: binding + 5, in: statement)
        }

        var matches: [(MemeItem, MemePageCursor)] = []
        matches.reserveCapacity(limit + 1)
        while sqlite3_step(statement) == SQLITE_ROW {
            let item = try Self.decoder.decode(
                MemeItem.self,
                from: try rowData(statement: statement, column: 0)
            )
            guard matcher.matchesEveryCandidate || item.matches(matcher: matcher) else { continue }
            let rowCursor = MemePageCursor(
                sortOrder: Int(sqlite3_column_int64(statement, 1)),
                createdAt: sqlite3_column_double(statement, 2),
                id: String(cString: sqlite3_column_text(statement, 3))
            )
            matches.append((item, rowCursor))
            if matches.count > limit { break }
        }

        let hasMore = matches.count > limit
        if hasMore { matches.removeLast() }
        return MemePage(
            items: matches.map(\.0),
            nextCursor: hasMore ? matches.last?.1 : nil
        )
    }

    func count(categoryID: UUID?, query: String) throws -> Int {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        let matcher = PercentFuzzyMatcher(query: query)
        if matcher.matchesEveryCandidate {
            let sql = categoryID == nil
                ? "SELECT COUNT(*) FROM meme_items"
                : "SELECT COUNT(*) FROM meme_items WHERE category_id = ?"
            let statement = try connection.prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let categoryID {
                try connection.bind(categoryID.uuidString, to: 1, in: statement)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }

        let sql = categoryID == nil
            ? "SELECT payload FROM meme_items"
            : "SELECT payload FROM meme_items WHERE category_id = ?"
        let statement = try connection.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let categoryID {
            try connection.bind(categoryID.uuidString, to: 1, in: statement)
        }
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let item = try Self.decoder.decode(
                MemeItem.self,
                from: try rowData(statement: statement, column: 0)
            )
            if item.matches(matcher: matcher) { count += 1 }
        }
        return count
    }

    func save(_ snapshot: MemeSnapshot) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        var changedCategoryCount = 0
        var deletedCategoryCount = 0
        var changedMemeCount = 0
        var deletedMemeCount = 0
        // Prepare the shared reader before the writer transaction without
        // decoding one throwaway note/OCR body. Close its 512 KiB pager when
        // this background snapshot finishes; deferred access reopens it.
        let preparedTextReader = snapshot.memes.contains(
            where: \.requiresDeferredTextRead
        )
        if preparedTextReader { prepareTextReaderConnection() }
        defer {
            if preparedTextReader { releaseTextReaderConnection() }
        }

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try connection.execute(
                "CREATE TEMP TABLE snapshot_meme_category_ids (id TEXT PRIMARY KEY NOT NULL)"
            )
            try connection.execute(
                "CREATE TEMP TABLE snapshot_meme_item_ids (id TEXT PRIMARY KEY NOT NULL)"
            )

            let rememberCategory = try connection.prepare(
                "INSERT INTO snapshot_meme_category_ids (id) VALUES (?)"
            )
            defer { sqlite3_finalize(rememberCategory) }
            let categoryUpsert = try connection.prepare(
                """
                INSERT INTO meme_categories (id, payload, position, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    payload = excluded.payload,
                    position = excluded.position,
                    created_at = excluded.created_at
                WHERE meme_categories.payload IS NOT excluded.payload
                   OR meme_categories.position != excluded.position
                """
            )
            defer { sqlite3_finalize(categoryUpsert) }
            for (index, category) in snapshot.categories.enumerated() {
                sqlite3_reset(rememberCategory)
                sqlite3_clear_bindings(rememberCategory)
                try connection.bind(
                    category.id.uuidString,
                    to: 1,
                    in: rememberCategory
                )
                try connection.stepDone(rememberCategory)

                sqlite3_reset(categoryUpsert)
                sqlite3_clear_bindings(categoryUpsert)
                try connection.bind(category.id.uuidString, to: 1, in: categoryUpsert)
                try connection.bind(
                    try Self.encoder.encode(category),
                    to: 2,
                    in: categoryUpsert
                )
                try connection.bind(Int64(index), to: 3, in: categoryUpsert)
                try connection.bind(
                    category.createdAt.timeIntervalSince1970,
                    to: 4,
                    in: categoryUpsert
                )
                try connection.stepDone(categoryUpsert)
                changedCategoryCount += Int(sqlite3_changes(connection.handle))
            }

            let rememberMeme = try connection.prepare(
                "INSERT INTO snapshot_meme_item_ids (id) VALUES (?)"
            )
            defer { sqlite3_finalize(rememberMeme) }
            let memeUpsert = try connection.prepare(
                """
                INSERT INTO meme_items (
                    id, payload, header_payload, note_body, ocr_body,
                    position, content_hash, category_id,
                    sort_order, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    payload = excluded.payload,
                    header_payload = excluded.header_payload,
                    note_body = excluded.note_body,
                    ocr_body = excluded.ocr_body,
                    position = excluded.position,
                    content_hash = excluded.content_hash,
                    category_id = excluded.category_id,
                    sort_order = excluded.sort_order,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at
                WHERE meme_items.payload IS NOT excluded.payload
                   OR meme_items.position != excluded.position
                """
            )
            defer { sqlite3_finalize(memeUpsert) }
            // A repository queue owns one autorelease pool for the whole save.
            // Drain JSON/UUID/SQLite bridge temporaries after every row so a
            // giant snapshot does not retain them until the transaction ends.
            for (index, meme) in snapshot.memes.enumerated() {
                try autoreleasepool {
                    sqlite3_reset(rememberMeme)
                    sqlite3_clear_bindings(rememberMeme)
                    try connection.bind(meme.id.uuidString, to: 1, in: rememberMeme)
                    try connection.stepDone(rememberMeme)

                    sqlite3_reset(memeUpsert)
                    sqlite3_clear_bindings(memeUpsert)
                    let row = try Self.encodedRow(meme)
                    try connection.bind(meme.id.uuidString, to: 1, in: memeUpsert)
                    try connection.bind(row.payload, to: 2, in: memeUpsert)
                    try connection.bind(row.header, to: 3, in: memeUpsert)
                    try connection.bind(row.note, to: 4, in: memeUpsert)
                    try connection.bind(row.ocrText, to: 5, in: memeUpsert)
                    try connection.bind(Int64(index), to: 6, in: memeUpsert)
                    try connection.bind(meme.contentHash, to: 7, in: memeUpsert)
                    if let categoryID = meme.categoryID {
                        try connection.bind(
                            categoryID.uuidString,
                            to: 8,
                            in: memeUpsert
                        )
                    } else if sqlite3_bind_null(memeUpsert, 8) != SQLITE_OK {
                        throw ClipboardHistoryDatabaseError.bind(connection.errorMessage)
                    }
                    try connection.bind(meme.sortOrder, to: 9, in: memeUpsert)
                    try connection.bind(
                        meme.createdAt.timeIntervalSince1970,
                        to: 10,
                        in: memeUpsert
                    )
                    try connection.bind(
                        meme.updatedAt.timeIntervalSince1970,
                        to: 11,
                        in: memeUpsert
                    )
                    try connection.stepDone(memeUpsert)
                    changedMemeCount += Int(sqlite3_changes(connection.handle))
                }
            }

            try connection.execute(
                """
                DELETE FROM meme_items
                WHERE id NOT IN (SELECT id FROM snapshot_meme_item_ids)
                """
            )
            deletedMemeCount = Int(sqlite3_changes(connection.handle))
            try connection.execute(
                """
                DELETE FROM meme_categories
                WHERE id NOT IN (SELECT id FROM snapshot_meme_category_ids)
                """
            )
            deletedCategoryCount = Int(sqlite3_changes(connection.handle))
            try markInitialized(connection)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        return MutationCounts(
            changedCategories: changedCategoryCount,
            deletedCategories: deletedCategoryCount,
            changedMemes: changedMemeCount,
            deletedMemes: deletedMemeCount
        )
    }

    func apply(
        categoryUpserts: [MemeCategory],
        deletedCategoryIDs: [UUID],
        memeUpserts: [MemeItem],
        deletedMemeIDs: [UUID],
        appendingCategoryIDs: Set<UUID>,
        appendingMemeIDs: Set<UUID>
    ) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        let categoryUpsertIDs = Set(categoryUpserts.map(\.id))
        let memeUpsertIDs = Set(memeUpserts.map(\.id))
        let effectiveDeletedCategories = deletedCategoryIDs.filter {
            !categoryUpsertIDs.contains($0)
        }
        let effectiveDeletedMemes = deletedMemeIDs.filter {
            !memeUpsertIDs.contains($0)
        }

        var nextCategoryPosition: Int64 = 0
        var nextMemePosition: Int64 = 0

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            nextCategoryPosition = try nextPosition(
                table: "meme_categories",
                connection: connection
            )
            nextMemePosition = try nextPosition(
                table: "meme_items",
                connection: connection
            )
            try delete(
                ids: effectiveDeletedCategories,
                table: "meme_categories",
                connection: connection
            )
            try delete(
                ids: effectiveDeletedMemes,
                table: "meme_items",
                connection: connection
            )

            if !categoryUpserts.isEmpty {
                let existingPosition = try connection.prepare(
                    "SELECT position FROM meme_categories WHERE id = ? LIMIT 1"
                )
                defer { sqlite3_finalize(existingPosition) }
                let statement = try connection.prepare(
                    """
                    INSERT INTO meme_categories (id, payload, position, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        position = excluded.position,
                        created_at = excluded.created_at
                    """
                )
                defer { sqlite3_finalize(statement) }
                for category in categoryUpserts {
                    let position: Int64
                    if !appendingCategoryIDs.contains(category.id),
                       let existing = try storedPosition(
                            id: category.id,
                            statement: existingPosition,
                            connection: connection
                       ) {
                        position = existing
                    } else {
                        position = nextCategoryPosition
                        nextCategoryPosition += 1
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try connection.bind(category.id.uuidString, to: 1, in: statement)
                    try connection.bind(try Self.encoder.encode(category), to: 2, in: statement)
                    try connection.bind(position, to: 3, in: statement)
                    try connection.bind(category.createdAt.timeIntervalSince1970, to: 4, in: statement)
                    try connection.stepDone(statement)
                }
            }

            if !memeUpserts.isEmpty {
                let existingPosition = try connection.prepare(
                    "SELECT position FROM meme_items WHERE id = ? LIMIT 1"
                )
                defer { sqlite3_finalize(existingPosition) }
                let statement = try connection.prepare(
                    """
                    INSERT INTO meme_items (
                        id, payload, header_payload, note_body, ocr_body,
                        position, content_hash, category_id,
                        sort_order, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        header_payload = excluded.header_payload,
                        note_body = excluded.note_body,
                        ocr_body = excluded.ocr_body,
                        position = excluded.position,
                        content_hash = excluded.content_hash,
                        category_id = excluded.category_id,
                        sort_order = excluded.sort_order,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    """
                )
                defer { sqlite3_finalize(statement) }
                // Archive imports can deliver a giant delta in one call too.
                for meme in memeUpserts {
                    try autoreleasepool {
                        let position: Int64
                        if !appendingMemeIDs.contains(meme.id),
                           let existing = try storedPosition(
                                id: meme.id,
                                statement: existingPosition,
                                connection: connection
                           ) {
                            position = existing
                        } else {
                            position = nextMemePosition
                            nextMemePosition += 1
                        }
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        let row = try Self.encodedRow(meme)
                        try connection.bind(meme.id.uuidString, to: 1, in: statement)
                        try connection.bind(row.payload, to: 2, in: statement)
                        try connection.bind(row.header, to: 3, in: statement)
                        try connection.bind(row.note, to: 4, in: statement)
                        try connection.bind(row.ocrText, to: 5, in: statement)
                        try connection.bind(position, to: 6, in: statement)
                        try connection.bind(meme.contentHash, to: 7, in: statement)
                        if let categoryID = meme.categoryID {
                            try connection.bind(categoryID.uuidString, to: 8, in: statement)
                        } else if sqlite3_bind_null(statement, 8) != SQLITE_OK {
                            throw ClipboardHistoryDatabaseError.bind(connection.errorMessage)
                        }
                        try connection.bind(meme.sortOrder, to: 9, in: statement)
                        try connection.bind(meme.createdAt.timeIntervalSince1970, to: 10, in: statement)
                        try connection.bind(meme.updatedAt.timeIntervalSince1970, to: 11, in: statement)
                        try connection.stepDone(statement)
                    }
                }
            }
            try markInitialized(connection)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        return MutationCounts(
            changedCategories: categoryUpserts.count,
            deletedCategories: effectiveDeletedCategories.count,
            changedMemes: memeUpserts.count,
            deletedMemes: effectiveDeletedMemes.count
        )
    }

    private func prepareSchema(_ connection: SQLiteConnection) throws {
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA synchronous = NORMAL")
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meme_categories (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                position INTEGER NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meme_items (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                header_payload BLOB,
                note_body TEXT,
                ocr_body TEXT,
                position INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                category_id TEXT,
                sort_order INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        try connection.addColumnIfNeeded(
            table: "meme_items",
            column: "header_payload",
            declaration: "BLOB"
        )
        try connection.addColumnIfNeeded(
            table: "meme_items",
            column: "note_body",
            declaration: "TEXT"
        )
        try connection.addColumnIfNeeded(
            table: "meme_items",
            column: "ocr_body",
            declaration: "TEXT"
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS storage_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
        try connection.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS meme_items_hash_idx ON meme_items(content_hash)"
        )
        try connection.execute(
            """
            CREATE INDEX IF NOT EXISTS meme_items_category_order_idx
            ON meme_items(category_id, sort_order, created_at)
            """
        )
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS meme_items_position_idx ON meme_items(position)"
        )
        try connection.execute("PRAGMA user_version = 2")
    }

    private func markInitialized(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            INSERT INTO storage_metadata (key, value) VALUES ('initialized', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
    }

    private func delete(
        ids: [UUID],
        table: String,
        connection: SQLiteConnection
    ) throws {
        guard !ids.isEmpty else { return }
        let statement = try connection.prepare("DELETE FROM \(table) WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try connection.bind(id.uuidString, to: 1, in: statement)
            try connection.stepDone(statement)
        }
    }

    private func rowData(statement: OpaquePointer, column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw ClipboardHistoryDatabaseError.decode("记录数据为空")
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func rowString(statement: OpaquePointer, column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: count),
            as: UTF8.self
        )
    }

    private static func encodedRow(
        _ meme: MemeItem
    ) throws -> (payload: Data, header: Data, note: String, ocrText: String) {
        let persistence = meme.persistenceProjection
        return (
            payload: try encoder.encode(persistence.meme),
            header: try encoder.encode(meme.metadataProjection),
            note: persistence.body.note,
            ocrText: persistence.body.ocrText
        )
    }

    private func nextPosition(
        table: String,
        connection: SQLiteConnection
    ) throws -> Int64 {
        let statement = try connection.prepare(
            "SELECT COALESCE(MAX(position) + 1, 0) FROM \(table)"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ClipboardHistoryDatabaseError.execute(connection.errorMessage)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func hasMissingHeader(
        table: String,
        connection: SQLiteConnection
    ) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT 1 FROM \(table) WHERE header_payload IS NULL LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else {
            throw ClipboardHistoryDatabaseError.execute(connection.errorMessage)
        }
        return false
    }

    private func storedPosition(
        id: UUID,
        statement: OpaquePointer,
        connection: SQLiteConnection
    ) throws -> Int64? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try connection.bind(id.uuidString, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return sqlite3_column_int64(statement, 0)
        }
        guard result == SQLITE_DONE else {
            throw ClipboardHistoryDatabaseError.execute(connection.errorMessage)
        }
        return nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
