import Foundation
import SQLite3

/// Thin wrappers over the system SQLite C API.
///
/// Why hand-rolled instead of a package: the only dependency this feature takes
/// is Apple's own `libsqlite3` (spec 007 plan, constitution VII.4). Keeping the
/// wrappers in one small file means the store itself reads like the queries it
/// runs, and the C-API details (transient bindings, finalize, error text) live
/// in exactly one place.
enum TranscriptStoreError: Error, CustomStringConvertible {
    case open(String)
    case execute(String)
    case prepare(String)
    case decode(String)

    var description: String {
        switch self {
        case .open(let message): return "transcript store could not open: \(message)"
        case .execute(let message): return "transcript store failed: \(message)"
        case .prepare(let message): return "transcript store could not prepare: \(message)"
        case .decode(let message): return "transcript store could not decode a record: \(message)"
        }
    }
}

/// SQLite copies the bound bytes immediately (`SQLITE_TRANSIENT`).
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Schema version stored in `meta`. Bumping it means "read the old files as
/// absent" rather than interpreting old columns under new rules.
enum TranscriptStoreSchema {
    static let version = 1

    static let statements = [
        """
        PRAGMA journal_mode = WAL;
        """,
        """
        PRAGMA busy_timeout = 5000;
        """,
        """
        PRAGMA synchronous = NORMAL;
        """,
        """
        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS session_state (
          scope       TEXT NOT NULL,
          session_id  TEXT NOT NULL,
          oldest_seq  INTEGER,
          newest_seq  INTEGER,
          has_more    INTEGER NOT NULL,
          last_opened REAL NOT NULL,
          PRIMARY KEY (scope, session_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS record (
          scope      TEXT NOT NULL,
          session_id TEXT NOT NULL,
          seq        INTEGER NOT NULL,
          kind       TEXT NOT NULL,
          payload    BLOB NOT NULL,
          PRIMARY KEY (scope, session_id, seq)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS record_by_seq ON record (scope, session_id, seq);
        """,
    ]
}

/// One open database handle. Not thread-safe by design: the store actor owns it.
final class SQLiteHandle {
    let raw: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite status \(status)"
            if let handle { sqlite3_close_v2(handle) }
            throw TranscriptStoreError.open(message)
        }
        raw = opened
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(raw, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(raw))
            throw TranscriptStoreError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw TranscriptStoreError.prepare(String(cString: sqlite3_errmsg(raw)))
        }
        return SQLiteStatement(handle: prepared, owner: self)
    }

    /// Runs one statement outside a transaction, for single-row writes.
    func run(_ sql: String, _ bind: (SQLiteStatement) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try bind(statement)
        while try statement.step() {}
    }

    func close() {
        sqlite3_close_v2(raw)
    }

    func errorText() -> String {
        String(cString: sqlite3_errmsg(raw))
    }
}

/// One prepared statement. `finalize` is required exactly once.
final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let owner: SQLiteHandle
    private var finished = false

    init(handle: OpaquePointer, owner: SQLiteHandle) {
        self.handle = handle
        self.owner = owner
    }

    deinit { finalize() }

    func bind(_ index: Int32, _ value: Int) {
        sqlite3_bind_int64(handle, index, Int64(value))
    }

    func bind(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(handle, index, value)
    }

    func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
    }

    func bind(_ index: Int32, _ value: Data) {
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
    }

    func bindNull(_ index: Int32) {
        sqlite3_bind_null(handle, index)
    }

    /// `true` when a row is available; `false` when the statement is done.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw TranscriptStoreError.execute(owner.errorText())
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func finalize() {
        guard !finished else { return }
        finished = true
        sqlite3_finalize(handle)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func optionalInt(_ column: Int32) -> Int? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : int(column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func bool(_ column: Int32) -> Bool {
        int(column) != 0
    }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }

    func data(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
