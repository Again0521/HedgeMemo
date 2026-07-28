import Foundation
import SQLite3

final class MemeDatabase {
    struct State {
        var categoryFingerprints: [UUID: Int]
        var categoryPositions: [UUID: Int64]
        var memeFingerprints: [UUID: Int]
        var memePositions: [UUID: Int64]
    }

    struct MutationCounts: Equatable {
        let changedCategories: Int
        let deletedCategories: Int
        let changedMemes: Int
        let deletedMemes: Int
    }

    private let url: URL

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

    func load() throws -> (snapshot: MemeSnapshot, state: State) {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)

        var categories: [MemeCategory] = []
        var categoryFingerprints: [UUID: Int] = [:]
        var categoryPositions: [UUID: Int64] = [:]
        let categoryStatement = try connection.prepare(
            "SELECT payload, position FROM meme_categories ORDER BY position ASC"
        )
        defer { sqlite3_finalize(categoryStatement) }
        while sqlite3_step(categoryStatement) == SQLITE_ROW {
            let data = try rowData(statement: categoryStatement, column: 0)
            let category = try Self.decoder.decode(MemeCategory.self, from: data)
            let position = sqlite3_column_int64(categoryStatement, 1)
            categories.append(category)
            categoryFingerprints[category.id] = Self.fingerprint(category)
            categoryPositions[category.id] = position
        }

        var memes: [MemeItem] = []
        var memeFingerprints: [UUID: Int] = [:]
        var memePositions: [UUID: Int64] = [:]
        let memeStatement = try connection.prepare(
            "SELECT payload, position FROM meme_items ORDER BY position ASC"
        )
        defer { sqlite3_finalize(memeStatement) }
        while sqlite3_step(memeStatement) == SQLITE_ROW {
            let data = try rowData(statement: memeStatement, column: 0)
            let meme = try Self.decoder.decode(MemeItem.self, from: data)
            let position = sqlite3_column_int64(memeStatement, 1)
            memes.append(meme)
            memeFingerprints[meme.id] = Self.fingerprint(meme)
            memePositions[meme.id] = position
        }

        return (
            MemeSnapshot(categories: categories, memes: memes),
            State(
                categoryFingerprints: categoryFingerprints,
                categoryPositions: categoryPositions,
                memeFingerprints: memeFingerprints,
                memePositions: memePositions
            )
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

    func save(_ snapshot: MemeSnapshot, state: inout State?) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        if state == nil {
            state = try load().state
        }
        let previous = state ?? State(
            categoryFingerprints: [:],
            categoryPositions: [:],
            memeFingerprints: [:],
            memePositions: [:]
        )

        let categoryChanges = changes(
            values: snapshot.categories,
            previousFingerprints: previous.categoryFingerprints,
            previousPositions: previous.categoryPositions
        )
        let memeChanges = changes(
            values: snapshot.memes,
            previousFingerprints: previous.memeFingerprints,
            previousPositions: previous.memePositions
        )

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try delete(
                ids: categoryChanges.deletedIDs,
                table: "meme_categories",
                connection: connection
            )
            try delete(
                ids: memeChanges.deletedIDs,
                table: "meme_items",
                connection: connection
            )

            if !categoryChanges.changed.isEmpty {
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
                for change in categoryChanges.changed {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try connection.bind(change.value.id.uuidString, to: 1, in: statement)
                    try connection.bind(try Self.encoder.encode(change.value), to: 2, in: statement)
                    try connection.bind(change.position, to: 3, in: statement)
                    try connection.bind(change.value.createdAt.timeIntervalSince1970, to: 4, in: statement)
                    try connection.stepDone(statement)
                }
            }

            if !memeChanges.changed.isEmpty {
                let statement = try connection.prepare(
                    """
                    INSERT INTO meme_items (
                        id, payload, position, content_hash, category_id,
                        sort_order, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        position = excluded.position,
                        content_hash = excluded.content_hash,
                        category_id = excluded.category_id,
                        sort_order = excluded.sort_order,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    """
                )
                defer { sqlite3_finalize(statement) }
                for change in memeChanges.changed {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try connection.bind(change.value.id.uuidString, to: 1, in: statement)
                    try connection.bind(try Self.encoder.encode(change.value), to: 2, in: statement)
                    try connection.bind(change.position, to: 3, in: statement)
                    try connection.bind(change.value.contentHash, to: 4, in: statement)
                    if let categoryID = change.value.categoryID {
                        try connection.bind(categoryID.uuidString, to: 5, in: statement)
                    } else if sqlite3_bind_null(statement, 5) != SQLITE_OK {
                        throw ClipboardHistoryDatabaseError.bind(connection.errorMessage)
                    }
                    try connection.bind(change.value.sortOrder, to: 6, in: statement)
                    try connection.bind(change.value.createdAt.timeIntervalSince1970, to: 7, in: statement)
                    try connection.bind(change.value.updatedAt.timeIntervalSince1970, to: 8, in: statement)
                    try connection.stepDone(statement)
                }
            }
            try markInitialized(connection)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        state = State(
            categoryFingerprints: categoryChanges.fingerprints,
            categoryPositions: categoryChanges.positions,
            memeFingerprints: memeChanges.fingerprints,
            memePositions: memeChanges.positions
        )
        return MutationCounts(
            changedCategories: categoryChanges.changed.count,
            deletedCategories: categoryChanges.deletedIDs.count,
            changedMemes: memeChanges.changed.count,
            deletedMemes: memeChanges.deletedIDs.count
        )
    }

    func apply(
        categoryUpserts: [MemeCategory],
        deletedCategoryIDs: [UUID],
        memeUpserts: [MemeItem],
        deletedMemeIDs: [UUID],
        appendingCategoryIDs: Set<UUID>,
        appendingMemeIDs: Set<UUID>,
        state: inout State?
    ) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try prepareSchema(connection)
        if state == nil {
            state = try load().state
        }
        var current = state ?? State(
            categoryFingerprints: [:],
            categoryPositions: [:],
            memeFingerprints: [:],
            memePositions: [:]
        )
        let categoryUpsertIDs = Set(categoryUpserts.map(\.id))
        let memeUpsertIDs = Set(memeUpserts.map(\.id))
        let effectiveDeletedCategories = deletedCategoryIDs.filter {
            !categoryUpsertIDs.contains($0)
        }
        let effectiveDeletedMemes = deletedMemeIDs.filter {
            !memeUpsertIDs.contains($0)
        }

        var nextCategoryPosition = (current.categoryPositions.values.max() ?? -1) + 1
        var nextMemePosition = (current.memePositions.values.max() ?? -1) + 1

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try delete(
                ids: effectiveDeletedCategories,
                table: "meme_categories",
                connection: connection
            )
            for id in effectiveDeletedCategories {
                current.categoryFingerprints.removeValue(forKey: id)
                current.categoryPositions.removeValue(forKey: id)
            }
            try delete(
                ids: effectiveDeletedMemes,
                table: "meme_items",
                connection: connection
            )
            for id in effectiveDeletedMemes {
                current.memeFingerprints.removeValue(forKey: id)
                current.memePositions.removeValue(forKey: id)
            }

            if !categoryUpserts.isEmpty {
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
                       let existing = current.categoryPositions[category.id] {
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
                    current.categoryFingerprints[category.id] = Self.fingerprint(category)
                    current.categoryPositions[category.id] = position
                }
            }

            if !memeUpserts.isEmpty {
                let statement = try connection.prepare(
                    """
                    INSERT INTO meme_items (
                        id, payload, position, content_hash, category_id,
                        sort_order, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        position = excluded.position,
                        content_hash = excluded.content_hash,
                        category_id = excluded.category_id,
                        sort_order = excluded.sort_order,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    """
                )
                defer { sqlite3_finalize(statement) }
                for meme in memeUpserts {
                    let position: Int64
                    if !appendingMemeIDs.contains(meme.id),
                       let existing = current.memePositions[meme.id] {
                        position = existing
                    } else {
                        position = nextMemePosition
                        nextMemePosition += 1
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try connection.bind(meme.id.uuidString, to: 1, in: statement)
                    try connection.bind(try Self.encoder.encode(meme), to: 2, in: statement)
                    try connection.bind(position, to: 3, in: statement)
                    try connection.bind(meme.contentHash, to: 4, in: statement)
                    if let categoryID = meme.categoryID {
                        try connection.bind(categoryID.uuidString, to: 5, in: statement)
                    } else if sqlite3_bind_null(statement, 5) != SQLITE_OK {
                        throw ClipboardHistoryDatabaseError.bind(connection.errorMessage)
                    }
                    try connection.bind(meme.sortOrder, to: 6, in: statement)
                    try connection.bind(meme.createdAt.timeIntervalSince1970, to: 7, in: statement)
                    try connection.bind(meme.updatedAt.timeIntervalSince1970, to: 8, in: statement)
                    try connection.stepDone(statement)
                    current.memeFingerprints[meme.id] = Self.fingerprint(meme)
                    current.memePositions[meme.id] = position
                }
            }
            try markInitialized(connection)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        state = current
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
                position INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                category_id TEXT,
                sort_order INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
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
        try connection.execute("PRAGMA user_version = 1")
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

    private struct Changes<Value: Hashable & Identifiable> where Value.ID == UUID {
        let changed: [(value: Value, position: Int64)]
        let deletedIDs: [UUID]
        let fingerprints: [UUID: Int]
        let positions: [UUID: Int64]
    }

    private func changes<Value: Hashable & Identifiable>(
        values: [Value],
        previousFingerprints: [UUID: Int],
        previousPositions: [UUID: Int64]
    ) -> Changes<Value> where Value.ID == UUID {
        var fingerprints: [UUID: Int] = [:]
        var positions: [UUID: Int64] = [:]
        var changed: [(value: Value, position: Int64)] = []
        fingerprints.reserveCapacity(values.count)
        positions.reserveCapacity(values.count)

        for (index, value) in values.enumerated() {
            let position = Int64(index)
            let fingerprint = Self.fingerprint(value)
            fingerprints[value.id] = fingerprint
            positions[value.id] = position
            if previousFingerprints[value.id] != fingerprint
                || previousPositions[value.id] != position {
                changed.append((value, position))
            }
        }
        let IDs = Set(fingerprints.keys)
        return Changes(
            changed: changed,
            deletedIDs: previousFingerprints.keys.filter { !IDs.contains($0) },
            fingerprints: fingerprints,
            positions: positions
        )
    }

    private static func fingerprint<T: Hashable>(_ value: T) -> Int {
        var hasher = Hasher()
        value.hash(into: &hasher)
        return hasher.finalize()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
