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
/// complete payload stays lossless in one row. Saves compare compact in-memory
/// fingerprints and only upsert rows whose values or ordering changed.
final class ClipboardHistoryDatabase {
    struct MutationCounts: Equatable {
        let changedEntries: Int
        let deletedEntries: Int
    }

    struct State {
        var fingerprints: [UUID: Int]
        var positions: [UUID: Int64]
        var nextPosition: Int64
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
            try connection.prepareSchema()
            let statement = try connection.prepare(
                "SELECT 1 FROM storage_metadata WHERE key = 'initialized' LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func load() throws -> (snapshot: ClipboardHistorySnapshot, state: State) {
        let connection = try SQLiteConnection(url: url)
        try connection.prepareSchema()

        var entries: [ClipboardEntry] = []
        var fingerprints: [UUID: Int] = [:]
        var positions: [UUID: Int64] = [:]
        var nextPosition: Int64 = 0
        let statement = try connection.prepare(
            "SELECT payload, position FROM clipboard_entries ORDER BY position ASC"
        )
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw ClipboardHistoryDatabaseError.decode("记录数据为空")
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: byteCount)
            let entry: ClipboardEntry
            do {
                entry = try Self.decoder.decode(ClipboardEntry.self, from: data)
            } catch {
                throw ClipboardHistoryDatabaseError.decode(error.localizedDescription)
            }
            let position = sqlite3_column_int64(statement, 1)
            entries.append(entry)
            fingerprints[entry.id] = Self.fingerprint(entry)
            positions[entry.id] = position
            nextPosition = max(nextPosition, position + 1)
        }
        guard sqlite3_errcode(connection.handle) == SQLITE_OK
                || sqlite3_errcode(connection.handle) == SQLITE_DONE else {
            throw ClipboardHistoryDatabaseError.execute(connection.errorMessage)
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
        return (
            ClipboardHistorySnapshot(entries: entries, settings: settings),
            State(
                fingerprints: fingerprints,
                positions: positions,
                nextPosition: nextPosition
            )
        )
    }

    func save(
        _ snapshot: ClipboardHistorySnapshot,
        state: inout State?
    ) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try connection.prepareSchema()
        if state == nil {
            state = try load().state
        }
        var currentState = state ?? State(fingerprints: [:], positions: [:], nextPosition: 0)

        var fingerprints: [UUID: Int] = [:]
        fingerprints.reserveCapacity(snapshot.entries.count)
        var positions: [UUID: Int64] = [:]
        positions.reserveCapacity(snapshot.entries.count)
        var changedEntries: [(entry: ClipboardEntry, position: Int64)] = []
        var lastPosition: Int64 = -1
        var nextPosition = max(currentState.nextPosition, 0)

        for entry in snapshot.entries {
            let fingerprint = Self.fingerprint(entry)
            fingerprints[entry.id] = fingerprint

            let position: Int64
            if let existing = currentState.positions[entry.id], existing > lastPosition {
                position = existing
            } else {
                position = max(nextPosition, lastPosition + 1)
                nextPosition = position + 1
            }
            positions[entry.id] = position
            lastPosition = position

            if currentState.fingerprints[entry.id] != fingerprint
                || currentState.positions[entry.id] != position {
                changedEntries.append((entry, position))
            }
        }

        let currentIDs = Set(fingerprints.keys)
        let deletedIDs = currentState.fingerprints.keys.filter { !currentIDs.contains($0) }
        var normalizedSettings = snapshot.settings
        normalizedSettings.normalize()
        let settingsData = try Self.encoder.encode(normalizedSettings)

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            if !changedEntries.isEmpty {
                let upsert = try connection.prepare(
                    """
                    INSERT INTO clipboard_entries (
                        id, payload, position, content_hash, kind,
                        created_at, updated_at, is_secret
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
                        position = excluded.position,
                        content_hash = excluded.content_hash,
                        kind = excluded.kind,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        is_secret = excluded.is_secret
                    """
                )
                defer { sqlite3_finalize(upsert) }
                for change in changedEntries {
                    sqlite3_reset(upsert)
                    sqlite3_clear_bindings(upsert)
                    let payload = try Self.encoder.encode(change.entry)
                    try connection.bind(change.entry.id.uuidString, to: 1, in: upsert)
                    try connection.bind(payload, to: 2, in: upsert)
                    try connection.bind(change.position, to: 3, in: upsert)
                    try connection.bind(change.entry.contentHash, to: 4, in: upsert)
                    try connection.bind(change.entry.kind.rawValue, to: 5, in: upsert)
                    try connection.bind(change.entry.createdAt.timeIntervalSince1970, to: 6, in: upsert)
                    try connection.bind(change.entry.updatedAt.timeIntervalSince1970, to: 7, in: upsert)
                    try connection.bind(change.entry.isSecret ? 1 : 0, to: 8, in: upsert)
                    try connection.stepDone(upsert)
                }
            }

            if !deletedIDs.isEmpty {
                let delete = try connection.prepare(
                    "DELETE FROM clipboard_entries WHERE id = ?"
                )
                defer { sqlite3_finalize(delete) }
                for id in deletedIDs {
                    sqlite3_reset(delete)
                    sqlite3_clear_bindings(delete)
                    try connection.bind(id.uuidString, to: 1, in: delete)
                    try connection.stepDone(delete)
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

        currentState.fingerprints = fingerprints
        currentState.positions = positions
        currentState.nextPosition = nextPosition
        state = currentState
        return MutationCounts(
            changedEntries: changedEntries.count,
            deletedEntries: deletedIDs.count
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
        settings: ClipboardHistorySettings,
        state: inout State?
    ) throws -> MutationCounts {
        let connection = try SQLiteConnection(url: url)
        try connection.prepareSchema()
        if state == nil {
            state = try load().state
        }
        var currentState = state ?? State(fingerprints: [:], positions: [:], nextPosition: 0)
        let upsertIDs = Set(upserts.map(\.id))
        let effectiveDeletedIDs = deletedIDs.filter { !upsertIDs.contains($0) }

        var normalizedSettings = settings
        normalizedSettings.normalize()
        let settingsData = try Self.encoder.encode(normalizedSettings)

        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
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
                    currentState.fingerprints.removeValue(forKey: id)
                    currentState.positions.removeValue(forKey: id)
                }
            }

            if !upserts.isEmpty {
                let upsert = try connection.prepare(
                    """
                    INSERT INTO clipboard_entries (
                        id, payload, position, content_hash, kind,
                        created_at, updated_at, is_secret
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload = excluded.payload,
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
                       let existingPosition = currentState.positions[entry.id] {
                        position = existingPosition
                    } else {
                        position = currentState.nextPosition
                        currentState.nextPosition += 1
                    }
                    sqlite3_reset(upsert)
                    sqlite3_clear_bindings(upsert)
                    try connection.bind(entry.id.uuidString, to: 1, in: upsert)
                    try connection.bind(try Self.encoder.encode(entry), to: 2, in: upsert)
                    try connection.bind(position, to: 3, in: upsert)
                    try connection.bind(entry.contentHash, to: 4, in: upsert)
                    try connection.bind(entry.kind.rawValue, to: 5, in: upsert)
                    try connection.bind(entry.createdAt.timeIntervalSince1970, to: 6, in: upsert)
                    try connection.bind(entry.updatedAt.timeIntervalSince1970, to: 7, in: upsert)
                    try connection.bind(entry.isSecret ? 1 : 0, to: 8, in: upsert)
                    try connection.stepDone(upsert)
                    currentState.fingerprints[entry.id] = Self.fingerprint(entry)
                    currentState.positions[entry.id] = position
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

        state = currentState
        return MutationCounts(
            changedEntries: upserts.count,
            deletedEntries: effectiveDeletedIDs.count
        )
    }

    private static func fingerprint(_ entry: ClipboardEntry) -> Int {
        var hasher = Hasher()
        entry.hash(into: &hasher)
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
    }

    deinit {
        sqlite3_close(handle)
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    func prepareSchema() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                position INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_secret INTEGER NOT NULL
            )
            """
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
        try execute("PRAGMA user_version = 1")
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
        let result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        guard result == SQLITE_OK else {
            throw ClipboardHistoryDatabaseError.bind(errorMessage)
        }
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
