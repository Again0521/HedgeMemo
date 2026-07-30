import Foundation
import SQLite3

enum ClipboardHistoryDatabaseError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .open(let message):
            "无法打开剪贴板数据库：\(message)"
        case .execute(let message):
            "无法更新剪贴板数据库：\(message)"
        case .prepare(let message):
            "无法准备剪贴板数据库查询：\(message)"
        case .bind(let message):
            "无法写入剪贴板数据库参数：\(message)"
        case .decode(let message):
            "无法读取剪贴板数据库内容：\(message)"
        }
    }
}

/// SQLite-backed clipboard metadata store.
///
/// Each entry remains encoded through `ClipboardEntry.Codable`, so model
/// evolution keeps the same compatibility contract as the former JSON file.
/// Frequently queried fields are duplicated into indexed columns, while the
/// complete payload stays lossless in one row. Snapshot saves compare each row
/// inside SQLite and use a temporary ID table, avoiding a second permanent
/// in-memory index of the whole history.
final class ClipboardHistoryDatabase: @unchecked Sendable {
    struct MutationCounts: Equatable {
        let changedEntries: Int
        let deletedEntries: Int
    }

    private let url: URL
    private let textReaderLock = NSLock()
    private var textReaderConnection: SQLiteConnection?
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
            try connection.prepareSchema()
            let statement = try connection.prepare(
                "SELECT 1 FROM storage_metadata WHERE key = 'initialized' LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func load(
        textProvider: ClipboardEntryTextProvider? = nil
    ) throws -> ClipboardHistorySnapshot {
        let connection = try SQLiteConnection(url: url)
        try connection.prepareSchema()
        lastBackfillRowCount = 0
        lastBackfillPeakResidentRowCount = 0

        var entries: [ClipboardEntry] = []
        let needsBackfill = try hasMissingHeader(
            table: "clipboard_entries",
            connection: connection
        )
        let stageBackfill: OpaquePointer?
        if needsBackfill {
            try connection.execute(
                """
                CREATE TEMP TABLE clipboard_metadata_backfill (
                    id TEXT PRIMARY KEY NOT NULL,
                    header_payload BLOB NOT NULL,
                    text_body TEXT,
                    content_category TEXT NOT NULL
                )
                """
            )
            stageBackfill = try connection.prepare(
                """
                INSERT INTO clipboard_metadata_backfill (
                    id, header_payload, text_body, content_category
                ) VALUES (?, ?, ?, ?)
                """
            )
        } else {
            stageBackfill = nil
        }
        defer {
            if let stageBackfill { sqlite3_finalize(stageBackfill) }
        }
        let statement = try connection.prepare(
            """
            SELECT header_payload, payload
            FROM clipboard_entries
            ORDER BY position ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        if needsBackfill {
            try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        }

        do {
            while sqlite3_step(statement) == SQLITE_ROW {
                let hasHeader = sqlite3_column_type(statement, 0) != SQLITE_NULL
                let payloadColumn: Int32 = hasHeader ? 0 : 1
                guard let bytes = sqlite3_column_blob(statement, payloadColumn) else {
                    throw ClipboardHistoryDatabaseError.decode("记录数据为空")
                }
                let byteCount = Int(sqlite3_column_bytes(statement, payloadColumn))
                let data = Data(bytes: bytes, count: byteCount)
                var entry: ClipboardEntry
                do {
                    entry = try Self.decoder.decode(ClipboardEntry.self, from: data)
                } catch {
                    throw ClipboardHistoryDatabaseError.decode(error.localizedDescription)
                }
                let automaticCategory = entry.automaticContentCategory
                let effectiveCategory = entry.contentCategory
                if !hasHeader, let stageBackfill {
                    lastBackfillRowCount += 1
                    lastBackfillPeakResidentRowCount = 1
                    sqlite3_reset(stageBackfill)
                    sqlite3_clear_bindings(stageBackfill)
                    try connection.bind(entry.id.uuidString, to: 1, in: stageBackfill)
                    try connection.bind(
                        try Self.encoder.encode(entry.metadataProjection),
                        to: 2,
                        in: stageBackfill
                    )
                    try connection.bind(
                        entry.decodedStoredText,
                        to: 3,
                        in: stageBackfill
                    )
                    try connection.bind(
                        effectiveCategory.rawValue,
                        to: 4,
                        in: stageBackfill
                    )
                    try connection.stepDone(stageBackfill)
                }
                if let textProvider {
                    entry.deferText(
                        to: textProvider,
                        automaticCategory: automaticCategory
                    )
                }
                entries.append(entry)
            }
            guard sqlite3_errcode(connection.handle) == SQLITE_OK
                    || sqlite3_errcode(connection.handle) == SQLITE_DONE else {
                throw ClipboardHistoryDatabaseError.execute(connection.errorMessage)
            }
            if needsBackfill {
                try applyStagedMetadataBackfill(connection: connection)
                try connection.execute("COMMIT")
            }
        } catch {
            if needsBackfill { try? connection.execute("ROLLBACK") }
            throw error
        }

        var settings = ClipboardHistorySettings()
        let settingsStatement = try connection.prepare(
            "SELECT payload FROM clipboard_settings WHERE id = 1"
        )
        defer { sqlite3_finalize(settingsStatement) }
        if sqlite3_step(settingsStatement) == SQLITE_ROW,
           let bytes = sqlite3_column_blob(settingsStatement, 0) {
            let byteCount = Int(sqlite3_column_bytes(settingsStatement, 0))
            do {
                settings = try Self.decoder.decode(
                    ClipboardHistorySettings.self,
                    from: Data(bytes: bytes, count: byteCount)
                )
            } catch {
                throw ClipboardHistoryDatabaseError.decode(error.localizedDescription)
            }
        }
        settings.normalize()
        return ClipboardHistorySnapshot(entries: entries, settings: settings)
    }

    func loadText(id: UUID) -> String? {
        textReaderLock.lock()
        defer { textReaderLock.unlock() }
        do {
            let connection: SQLiteConnection
            if let existing = textReaderConnection {
                connection = existing
            } else {
                let created = try SQLiteConnection(url: url)
                try created.prepareSchema()
                textReaderConnection = created
                connection = created
            }
            let statement = try connection.prepare(
                "SELECT text_body, payload FROM clipboard_entries WHERE id = ? LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(id.uuidString, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(statement, 0) != SQLITE_NULL,
               let text = sqlite3_column_text(statement, 0) {
                let count = Int(sqlite3_column_bytes(statement, 0))
                return String(
                    decoding: UnsafeBufferPointer(start: text, count: count),
                    as: UTF8.self
                )
            }
            guard let bytes = sqlite3_column_blob(statement, 1) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 1))
            return try Self.decoder.decode(
                ClipboardEntry.self,
                from: Data(bytes: bytes, count: count)
            ).decodedStoredText
        } catch {
            return nil
        }
    }

    /// Deferred bodies use one reusable reader while a panel is active. Close
    /// it when presentation caches are purged so SQLite releases its pager,
    /// schema and statement-lookaside memory while HedgeMemo sits in the
    /// background. The next body access recreates it transparently.
    func releaseTextReaderConnection() {
        textReaderLock.withLock {
            textReaderConnection = nil
        }
    }

    var hasTextReaderConnection: Bool {
        textReaderLock.withLock { textReaderConnection != nil }
    }

    private func applyStagedMetadataBackfill(
        connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            UPDATE clipboard_entries
            SET header_payload = (
                    SELECT header_payload
                    FROM clipboard_metadata_backfill
                    WHERE clipboard_metadata_backfill.id = clipboard_entries.id
                ),
                text_body = (
                    SELECT text_body
                    FROM clipboard_metadata_backfill
                    WHERE clipboard_metadata_backfill.id = clipboard_entries.id
                ),
                content_category = (
                    SELECT content_category
                    FROM clipboard_metadata_backfill
                    WHERE clipboard_metadata_backfill.id = clipboard_entries.id
                )
            WHERE id IN (SELECT id FROM clipboard_metadata_backfill)
            """
        )
    }

    func save(_ snapshot: ClipboardHistorySnapshot) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try connection.prepareSchema()
        var changedEntryCount = 0
        var deletedEntryCount = 0
        var lastPosition: Int64 = -1
        var nextPosition: Int64 = 0
        var normalizedSettings = snapshot.settings
        normalizedSettings.normalize()
        let settingsData = try Self.encoder.encode(normalizedSettings)
        // A deferred entry resolves its body through the shared read
        // connection. Open/configure that connection before taking the write
        // transaction; otherwise its first PRAGMA can wait behind our writer.
        if let firstEntry = snapshot.entries.first {
            _ = loadText(id: firstEntry.id)
        }

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            nextPosition = try self.nextPosition(
                table: "clipboard_entries",
                connection: connection
            )
            try connection.execute(
                "CREATE TEMP TABLE snapshot_clipboard_ids (id TEXT PRIMARY KEY NOT NULL)"
            )
            let rememberID = try connection.prepare(
                "INSERT INTO snapshot_clipboard_ids (id) VALUES (?)"
            )
            defer { sqlite3_finalize(rememberID) }
            let existingPosition = try connection.prepare(
                "SELECT position FROM clipboard_entries WHERE id = ? LIMIT 1"
            )
            defer { sqlite3_finalize(existingPosition) }
            let upsert = try connection.prepare(
                """
                INSERT INTO clipboard_entries (
                    id, payload, header_payload, text_body, content_category,
                    position, content_hash, kind, created_at, updated_at, is_secret
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    payload = excluded.payload,
                    header_payload = excluded.header_payload,
                    text_body = excluded.text_body,
                    content_category = excluded.content_category,
                    position = excluded.position,
                    content_hash = excluded.content_hash,
                    kind = excluded.kind,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    is_secret = excluded.is_secret
                WHERE clipboard_entries.payload IS NOT excluded.payload
                   OR clipboard_entries.position != excluded.position
                """
            )
            defer { sqlite3_finalize(upsert) }

            for entry in snapshot.entries {
                sqlite3_reset(rememberID)
                sqlite3_clear_bindings(rememberID)
                try connection.bind(entry.id.uuidString, to: 1, in: rememberID)
                try connection.stepDone(rememberID)

                let priorPosition = try storedPosition(
                    id: entry.id,
                    statement: existingPosition,
                    connection: connection
                )
                let position: Int64
                if let priorPosition, priorPosition > lastPosition {
                    position = priorPosition
                } else {
                    position = max(nextPosition, lastPosition + 1)
                    nextPosition = position + 1
                }
                lastPosition = position

                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                let row = try Self.encodedRow(entry)
                try connection.bind(entry.id.uuidString, to: 1, in: upsert)
                try connection.bind(row.payload, to: 2, in: upsert)
                try connection.bind(row.header, to: 3, in: upsert)
                try connection.bind(row.text, to: 4, in: upsert)
                try connection.bind(row.category, to: 5, in: upsert)
                try connection.bind(position, to: 6, in: upsert)
                try connection.bind(entry.contentHash, to: 7, in: upsert)
                try connection.bind(entry.kind.rawValue, to: 8, in: upsert)
                try connection.bind(entry.createdAt.timeIntervalSince1970, to: 9, in: upsert)
                try connection.bind(entry.updatedAt.timeIntervalSince1970, to: 10, in: upsert)
                try connection.bind(entry.isSecret ? 1 : 0, to: 11, in: upsert)
                try connection.stepDone(upsert)
                changedEntryCount += Int(sqlite3_changes(connection.handle))
            }

            try connection.execute(
                """
                DELETE FROM clipboard_entries
                WHERE id NOT IN (SELECT id FROM snapshot_clipboard_ids)
                """
            )
            deletedEntryCount = Int(sqlite3_changes(connection.handle))

            let settingsStatement = try connection.prepare(
                """
                INSERT INTO clipboard_settings (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """
            )
            defer { sqlite3_finalize(settingsStatement) }
            try connection.bind(settingsData, to: 1, in: settingsStatement)
            try connection.stepDone(settingsStatement)
            try connection.markInitialized()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        return MutationCounts(
            changedEntries: changedEntryCount,
            deletedEntries: deletedEntryCount
        )
    }

    /// Applies a mutation whose complete affected row set is already known by
    /// the store. This is the normal capture path: it avoids constructing,
    /// hashing and comparing a snapshot of every historical entry just to add
    /// one new row and optionally trim one old row.
    func apply(
        upserts: [ClipboardEntry],
        deletedIDs: [UUID],
        appendingIDs: Set<UUID>,
        settings: ClipboardHistorySettings
    ) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try connection.prepareSchema()
        let upsertIDs = Set(upserts.map(\.id))
        let effectiveDeletedIDs = deletedIDs.filter { !upsertIDs.contains($0) }
        var nextPosition: Int64 = 0

        var normalizedSettings = settings
        normalizedSettings.normalize()
        let settingsData = try Self.encoder.encode(normalizedSettings)

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            nextPosition = try self.nextPosition(
                table: "clipboard_entries",
                connection: connection
            )
            if !effectiveDeletedIDs.isEmpty {
                let delete = try connection.prepare(
                    "DELETE FROM clipboard_entries WHERE id = ?"
                )
                defer { sqlite3_finalize(delete) }
                for id in effectiveDeletedIDs {
                    sqlite3_reset(delete)
                    sqlite3_clear_bindings(delete)
                    try connection.bind(id.uuidString, to: 1, in: delete)
                    try connection.stepDone(delete)
                }
            }

            if !upserts.isEmpty {
                let existingPosition = try connection.prepare(
                    "SELECT position FROM clipboard_entries WHERE id = ? LIMIT 1"
                )
                defer { sqlite3_finalize(existingPosition) }
                let upsert = try connection.prepare(
                    """
                    INSERT INTO clipboard_entries (
                        id, payload, header_payload, text_body, content_category,
                        position, content_hash, kind, created_at, updated_at, is_secret
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        header_payload = excluded.header_payload,
                        text_body = excluded.text_body,
                        content_category = excluded.content_category,
                        position = excluded.position,
                        content_hash = excluded.content_hash,
                        kind = excluded.kind,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        is_secret = excluded.is_secret
                    """
                )
                defer { sqlite3_finalize(upsert) }
                for entry in upserts {
                    let position: Int64
                    if !appendingIDs.contains(entry.id),
                       let existing = try storedPosition(
                            id: entry.id,
                            statement: existingPosition,
                            connection: connection
                       ) {
                        position = existing
                    } else {
                        position = nextPosition
                        nextPosition += 1
                    }
                    sqlite3_reset(upsert)
                    sqlite3_clear_bindings(upsert)
                    let row = try Self.encodedRow(entry)
                    try connection.bind(entry.id.uuidString, to: 1, in: upsert)
                    try connection.bind(row.payload, to: 2, in: upsert)
                    try connection.bind(row.header, to: 3, in: upsert)
                    try connection.bind(row.text, to: 4, in: upsert)
                    try connection.bind(row.category, to: 5, in: upsert)
                    try connection.bind(position, to: 6, in: upsert)
                    try connection.bind(entry.contentHash, to: 7, in: upsert)
                    try connection.bind(entry.kind.rawValue, to: 8, in: upsert)
                    try connection.bind(entry.createdAt.timeIntervalSince1970, to: 9, in: upsert)
                    try connection.bind(entry.updatedAt.timeIntervalSince1970, to: 10, in: upsert)
                    try connection.bind(entry.isSecret ? 1 : 0, to: 11, in: upsert)
                    try connection.stepDone(upsert)
                }
            }

            let settingsStatement = try connection.prepare(
                """
                INSERT INTO clipboard_settings (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """
            )
            defer { sqlite3_finalize(settingsStatement) }
            try connection.bind(settingsData, to: 1, in: settingsStatement)
            try connection.stepDone(settingsStatement)
            try connection.markInitialized()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        return MutationCounts(
            changedEntries: upserts.count,
            deletedEntries: effectiveDeletedIDs.count
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

    private static func encodedRow(
        _ entry: ClipboardEntry
    ) throws -> (payload: Data, header: Data, text: String?, category: String) {
        let persistence = entry.persistenceProjection
        return (
            payload: try encoder.encode(persistence.entry),
            header: try encoder.encode(entry.metadataProjection),
            text: persistence.text,
            category: entry.contentCategory.rawValue
        )
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

final class SQLiteConnection {
    let handle: OpaquePointer

    init(url: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite error \(result)"
            if let database { sqlite3_close(database) }
            throw ClipboardHistoryDatabaseError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5_000)
        // SQLite's default cache budget is much larger than a menu-bar
        // utility needs, and it applies independently to every connection.
        // A negative value is a KiB ceiling rather than a page count.
        try execute("PRAGMA cache_size = -512")
        try execute("PRAGMA cache_spill = ON")
        try execute("PRAGMA temp_store = FILE")
    }

    deinit {
        sqlite3_close(handle)
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    var configuredCacheSizeKiB: Int {
        let statement = try? prepare("PRAGMA cache_size")
        guard let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return abs(Int(sqlite3_column_int64(statement, 0)))
    }

    var configuredMmapSizeBytes: Int {
        let statement = try? prepare("PRAGMA mmap_size")
        guard let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func prepareSchema() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                header_payload BLOB,
                text_body TEXT,
                content_category TEXT,
                position INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_secret INTEGER NOT NULL
            )
            """
        )
        try addColumnIfNeeded(
            table: "clipboard_entries",
            column: "header_payload",
            declaration: "BLOB"
        )
        try addColumnIfNeeded(
            table: "clipboard_entries",
            column: "text_body",
            declaration: "TEXT"
        )
        try addColumnIfNeeded(
            table: "clipboard_entries",
            column: "content_category",
            declaration: "TEXT"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS clipboard_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                payload BLOB NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS storage_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS clipboard_entries_position_idx ON clipboard_entries(position)"
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS clipboard_entries_hash_secret_idx
            ON clipboard_entries(content_hash, is_secret)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS clipboard_entries_created_idx
            ON clipboard_entries(created_at DESC, id)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS clipboard_entries_kind_created_idx
            ON clipboard_entries(kind, created_at DESC, id)
            """
        )
        try execute("PRAGMA user_version = 2")
    }

    func addColumnIfNeeded(
        table: String,
        column: String,
        declaration: String
    ) throws {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == column {
                exists = true
                break
            }
        }
        if !exists {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
        }
    }

    func markInitialized() throws {
        try execute(
            """
            INSERT INTO storage_metadata (key, value) VALUES ('initialized', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw ClipboardHistoryDatabaseError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ClipboardHistoryDatabaseError.prepare(errorMessage)
        }
        return statement
    }

    func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withCString { bytes in
            sqlite3_bind_text(
                statement,
                index,
                bytes,
                Int32(value.utf8.count),
                sqliteTransient
            )
        }
        guard result == SQLITE_OK else {
            throw ClipboardHistoryDatabaseError.bind(errorMessage)
        }
    }

    func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw ClipboardHistoryDatabaseError.bind(errorMessage)
            }
            return
        }
        try bind(value, to: index, in: statement)
    }

    func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                sqliteTransient
            )
        }
        guard result == SQLITE_OK else {
            throw ClipboardHistoryDatabaseError.bind(errorMessage)
        }
    }

    func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw ClipboardHistoryDatabaseError.bind(errorMessage)
        }
    }

    func bind(_ value: Int, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK else {
            throw ClipboardHistoryDatabaseError.bind(errorMessage)
        }
    }

    func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw ClipboardHistoryDatabaseError.bind(errorMessage)
        }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardHistoryDatabaseError.execute(errorMessage)
        }
    }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
