import Foundation
import SQLite3

/// Exact, disposable de-duplication for bulk imports.
///
/// A Swift `Set<String>` duplicates every content hash already retained by the
/// Store and grows again for each accepted archive record. This index keeps the
/// same exact PRIMARY KEY semantics in a temporary SQLite file, with only the
/// current hash crossing the Swift heap at any moment.
final class FileBackedHashIndex: @unchecked Sendable {
    private let directoryURL: URL
    let storageURL: URL
    private var connection: SQLiteConnection?
    private var insertStatement: OpaquePointer?
    private var deleteStatement: OpaquePointer?
    private var setPositionStatement: OpaquePointer?
    private var positionStatement: OpaquePointer?
    private var stageTextStatement: OpaquePointer?
    private var removeTextStatement: OpaquePointer?
    private var textStatement: OpaquePointer?
    private let textStatementLock = NSLock()

    private(set) var storedHashCount = 0
    private(set) var peakStoredHashCount = 0
    private(set) var peakResidentHashCount = 0
    private(set) var peakResidentKeyByteCount = 0
    private(set) var stagedTextBodyCount = 0
    private(set) var currentStagedTextBodyCount = 0
    private(set) var peakResidentTextBodyCount = 0
    private(set) var configuredCacheSizeKiB = 0
    private(set) var configuredMmapSizeBytes = 0

    init<Hashes: Sequence>(
        existingHashes: Hashes,
        fileManager: FileManager = .default
    ) throws where Hashes.Element == String {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "hedgememo-import-hashes-\(UUID().uuidString)",
            isDirectory: true
        )
        directoryURL = directory
        storageURL = directory.appendingPathComponent("hashes.sqlite3")

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let connection = try SQLiteConnection(url: storageURL)
            self.connection = connection
            // The index is disposable and never shared. Avoid WAL sidecars and
            // durability work while keeping the main database's settings intact.
            try connection.execute("PRAGMA journal_mode = OFF")
            try connection.execute("PRAGMA synchronous = OFF")
            // This connection exists only for one streaming import and keeps a
            // single transaction open. Its B-tree working set is tiny, so the
            // general repository connection's 512 KiB cache would be wasted
            // resident memory. Keep enough pages for traversal and force all
            // larger scratch state to the disposable file.
            try connection.execute("PRAGMA cache_size = -128")
            try connection.execute("PRAGMA cache_spill = ON")
            try connection.execute("PRAGMA mmap_size = 0")
            configuredCacheSizeKiB = connection.configuredCacheSizeKiB
            configuredMmapSizeBytes = connection.configuredMmapSizeBytes
            try connection.execute(
                """
                CREATE TABLE known_hashes (
                    value BLOB PRIMARY KEY NOT NULL,
                    position INTEGER
                ) WITHOUT ROWID
                """
            )
            try connection.execute(
                """
                CREATE TABLE staged_text_bodies (
                    id TEXT PRIMARY KEY NOT NULL,
                    body TEXT NOT NULL
                ) WITHOUT ROWID
                """
            )
            insertStatement = try connection.prepare(
                """
                INSERT INTO known_hashes (value) VALUES (?)
                ON CONFLICT(value) DO NOTHING
                RETURNING 1
                """
            )
            deleteStatement = try connection.prepare(
                "DELETE FROM known_hashes WHERE value = ? RETURNING 1"
            )
            setPositionStatement = try connection.prepare(
                "UPDATE known_hashes SET position = ? WHERE value = ? RETURNING 1"
            )
            positionStatement = try connection.prepare(
                "SELECT position FROM known_hashes WHERE value = ? LIMIT 1"
            )
            stageTextStatement = try connection.prepare(
                "INSERT INTO staged_text_bodies (id, body) VALUES (?, ?)"
            )
            removeTextStatement = try connection.prepare(
                "DELETE FROM staged_text_bodies WHERE id = ? RETURNING 1"
            )
            textStatement = try connection.prepare(
                "SELECT body FROM staged_text_bodies WHERE id = ? LIMIT 1"
            )

            try connection.execute("BEGIN TRANSACTION")
            do {
                for hash in existingHashes {
                    _ = try insertIfNew(hash)
                }
                // Keep one transaction open for the disposable index's entire
                // lifetime. Later hashes, positions and text bodies otherwise
                // each pay an autocommit boundary. Reads use this same
                // serialized connection and can see the staged rows directly;
                // closing/deleting the database is the only finalization this
                // scratch data needs.
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }
        } catch {
            close()
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    @discardableResult
    func insertIfNew(_ hash: String) throws -> Bool {
        try insertIfNew(Data(hash.utf8))
    }

    @discardableResult
    func insertIfNew(_ key: Data) throws -> Bool {
        guard let connection, let insertStatement else {
            throw ClipboardHistoryDatabaseError.execute(
                "临时导入索引已经关闭"
            )
        }
        peakResidentHashCount = max(peakResidentHashCount, 1)
        peakResidentKeyByteCount = max(peakResidentKeyByteCount, key.count)
        sqlite3_reset(insertStatement)
        sqlite3_clear_bindings(insertStatement)
        try connection.bind(key, to: 1, in: insertStatement)
        let result = sqlite3_step(insertStatement)
        let inserted: Bool
        if result == SQLITE_ROW {
            guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                throw ClipboardHistoryDatabaseError.execute(
                    connection.errorMessage
                )
            }
            inserted = true
        } else if result == SQLITE_DONE {
            inserted = false
        } else {
            throw ClipboardHistoryDatabaseError.execute(
                connection.errorMessage
            )
        }
        if inserted {
            storedHashCount += 1
            peakStoredHashCount = max(peakStoredHashCount, storedHashCount)
        }
        return inserted
    }

    func remove(_ hash: String) throws {
        try remove(Data(hash.utf8))
    }

    func remove(_ key: Data) throws {
        guard let connection, let deleteStatement else {
            throw ClipboardHistoryDatabaseError.execute(
                "临时导入索引已经关闭"
            )
        }
        peakResidentHashCount = max(peakResidentHashCount, 1)
        peakResidentKeyByteCount = max(peakResidentKeyByteCount, key.count)
        sqlite3_reset(deleteStatement)
        sqlite3_clear_bindings(deleteStatement)
        try connection.bind(key, to: 1, in: deleteStatement)
        let result = sqlite3_step(deleteStatement)
        if result == SQLITE_ROW {
            guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                throw ClipboardHistoryDatabaseError.execute(
                    connection.errorMessage
                )
            }
            storedHashCount -= 1
        } else if result != SQLITE_DONE {
            throw ClipboardHistoryDatabaseError.execute(
                connection.errorMessage
            )
        }
    }

    func setPosition(_ position: Int, for key: String) throws {
        try setPosition(position, for: Data(key.utf8))
    }

    func setPosition(_ position: Int, for key: Data) throws {
        guard let connection, let setPositionStatement else {
            throw ClipboardHistoryDatabaseError.execute(
                "临时导入索引已经关闭"
            )
        }
        peakResidentHashCount = max(peakResidentHashCount, 1)
        peakResidentKeyByteCount = max(peakResidentKeyByteCount, key.count)
        sqlite3_reset(setPositionStatement)
        sqlite3_clear_bindings(setPositionStatement)
        try connection.bind(position, to: 1, in: setPositionStatement)
        try connection.bind(key, to: 2, in: setPositionStatement)
        guard sqlite3_step(setPositionStatement) == SQLITE_ROW,
              sqlite3_step(setPositionStatement) == SQLITE_DONE else {
            throw ClipboardHistoryDatabaseError.execute(
                connection.errorMessage
            )
        }
    }

    func position(for key: String) throws -> Int? {
        try position(for: Data(key.utf8))
    }

    func position(for key: Data) throws -> Int? {
        guard let connection, let positionStatement else {
            throw ClipboardHistoryDatabaseError.execute(
                "临时导入索引已经关闭"
            )
        }
        peakResidentHashCount = max(peakResidentHashCount, 1)
        peakResidentKeyByteCount = max(peakResidentKeyByteCount, key.count)
        sqlite3_reset(positionStatement)
        sqlite3_clear_bindings(positionStatement)
        try connection.bind(key, to: 1, in: positionStatement)
        let result = sqlite3_step(positionStatement)
        if result == SQLITE_ROW {
            guard sqlite3_column_type(positionStatement, 0) != SQLITE_NULL
            else { return nil }
            return Int(sqlite3_column_int64(positionStatement, 0))
        }
        guard result == SQLITE_DONE else {
            throw ClipboardHistoryDatabaseError.execute(
                connection.errorMessage
            )
        }
        return nil
    }

    /// Moves an accepted archive body out of the Swift model immediately.
    /// The disposable database shares this index's already-bounded SQLite
    /// connection, so text staging does not add another pager/cache budget.
    func stageText(_ text: String, for id: UUID) throws {
        try textStatementLock.withLock {
            guard let connection, let stageTextStatement else {
                throw ClipboardHistoryDatabaseError.execute(
                    "临时导入正文存储已经关闭"
                )
            }
            peakResidentTextBodyCount = max(peakResidentTextBodyCount, 1)
            sqlite3_reset(stageTextStatement)
            sqlite3_clear_bindings(stageTextStatement)
            defer {
                sqlite3_reset(stageTextStatement)
                sqlite3_clear_bindings(stageTextStatement)
            }
            try connection.bind(id.uuidString, to: 1, in: stageTextStatement)
            try connection.bind(text, to: 2, in: stageTextStatement)
            try connection.stepDone(stageTextStatement)
            stagedTextBodyCount += 1
            currentStagedTextBodyCount += 1
        }
    }

    func removeStagedText(for id: UUID) throws {
        try textStatementLock.withLock {
            guard let connection, let removeTextStatement else {
                throw ClipboardHistoryDatabaseError.execute(
                    "临时导入正文存储已经关闭"
                )
            }
            sqlite3_reset(removeTextStatement)
            sqlite3_clear_bindings(removeTextStatement)
            defer {
                sqlite3_reset(removeTextStatement)
                sqlite3_clear_bindings(removeTextStatement)
            }
            try connection.bind(id.uuidString, to: 1, in: removeTextStatement)
            let result = sqlite3_step(removeTextStatement)
            if result == SQLITE_ROW {
                guard sqlite3_step(removeTextStatement) == SQLITE_DONE else {
                    throw ClipboardHistoryDatabaseError.execute(
                        connection.errorMessage
                    )
                }
                currentStagedTextBodyCount -= 1
            } else if result != SQLITE_DONE {
                throw ClipboardHistoryDatabaseError.execute(
                    connection.errorMessage
                )
            }
        }
    }

    func makeTextProvider() -> ClipboardEntryTextProvider {
        ClipboardEntryTextProvider(cachesValues: false) { [self] id in
            loadStagedText(for: id)
        }
    }

    private func loadStagedText(for id: UUID) -> String? {
        textStatementLock.withLock {
            guard let connection, let textStatement else { return nil }
            sqlite3_reset(textStatement)
            sqlite3_clear_bindings(textStatement)
            defer {
                sqlite3_reset(textStatement)
                sqlite3_clear_bindings(textStatement)
            }
            do {
                try connection.bind(id.uuidString, to: 1, in: textStatement)
                let result = sqlite3_step(textStatement)
                if result == SQLITE_ROW,
                   let bytes = sqlite3_column_text(textStatement, 0) {
                    let count = Int(sqlite3_column_bytes(textStatement, 0))
                    return String(
                        decoding: UnsafeBufferPointer(
                            start: bytes,
                            count: count
                        ),
                        as: UTF8.self
                    )
                }
                guard result == SQLITE_DONE else { return nil }
                return nil
            } catch {
                return nil
            }
        }
    }

    private func close() {
        if let insertStatement {
            sqlite3_finalize(insertStatement)
            self.insertStatement = nil
        }
        if let deleteStatement {
            sqlite3_finalize(deleteStatement)
            self.deleteStatement = nil
        }
        if let setPositionStatement {
            sqlite3_finalize(setPositionStatement)
            self.setPositionStatement = nil
        }
        if let positionStatement {
            sqlite3_finalize(positionStatement)
            self.positionStatement = nil
        }
        if let stageTextStatement {
            sqlite3_finalize(stageTextStatement)
            self.stageTextStatement = nil
        }
        if let removeTextStatement {
            sqlite3_finalize(removeTextStatement)
            self.removeTextStatement = nil
        }
        if let textStatement {
            sqlite3_finalize(textStatement)
            self.textStatement = nil
        }
        connection = nil
    }
}
