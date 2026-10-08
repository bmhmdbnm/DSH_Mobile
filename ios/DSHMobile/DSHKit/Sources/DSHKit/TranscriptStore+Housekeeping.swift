import Foundation

/// Housekeeping: opening scope databases, archiving what nobody opened, keeping
/// the whole cache inside its byte budget, and telling the settings screen how
/// much it occupies.
///
/// Split from `TranscriptStore.swift` so each file stays readable (and under the
/// project's 500-line default); the store's own type is unchanged.
extension TranscriptStore {

    /// One database per computer, opened on first use and kept open.
    ///
    /// On the very first open of a fresh deployment the legacy JSON files are
    /// imported and removed (`legacyImport`), so an upgrade does not look like
    /// "my history disappeared".
    func database(scope: String) throws -> SQLiteHandle {
        if let existing = handles[scope] { return existing }
        let directory = root.appendingPathComponent(Self.slug(scope), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try SQLiteHandle(path: directory.appendingPathComponent("records.sqlite").path)
        for statement in TranscriptStoreSchema.statements {
            try handle.execute(statement)
        }
        try handle.run("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)") { statement in
            statement.bind(1, String(TranscriptStoreSchema.version))
        }
        handles[scope] = handle
        try importLegacyFiles(in: directory, scope: scope, handle: handle)
        return handle
    }

    /// Every scope directory that exists on disk (one per computer).
    func scopesOnDisk() -> [String] {
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }

    /// Drops every session whose last open is older than `maxAge`.
    /// - Returns: how many sessions were removed.
    @discardableResult
    public func evictExpired() throws -> Int {
        let deadline = now().addingTimeInterval(-maxAge).timeIntervalSince1970
        var removed = 0
        for scope in scopesOnDisk() {
            let handle = try database(scope: scope)
            removed += try removeSessions(handle, scope: scope, olderThan: deadline)
            if removed > 0 { try? handle.execute("VACUUM") }
        }
        return removed
    }

    /// Drops least-recently-opened sessions until the cache fits `budgetBytes`.
    ///
    /// Accounting is by **live payload bytes**, not file size: SQLite keeps freed
    /// pages in the file until `VACUUM`, so a file-size loop would keep deleting
    /// sessions that no longer occupy anything. The file is compacted once at the
    /// end.
    /// - Returns: how many sessions were removed.
    @discardableResult
    public func enforceBudget() throws -> Int {
        var candidates: [(scope: String, sessionId: String, opened: Double, bytes: Int)] = []
        for scope in scopesOnDisk() {
            candidates.append(contentsOf: try sessions(try database(scope: scope), scope: scope))
        }
        var total = candidates.reduce(0) { $0 + $1.bytes }
        guard total > budgetBytes else { return 0 }
        var removed = 0
        for candidate in candidates.sorted(by: { $0.opened < $1.opened }) {
            guard total > budgetBytes else { break }
            try deleteSession(try database(scope: candidate.scope),
                              scope: candidate.scope, sessionId: candidate.sessionId)
            total -= candidate.bytes
            removed += 1
        }
        for scope in scopesOnDisk() { try? database(scope: scope).execute("VACUUM") }
        return removed
    }

    /// Bytes occupied by every scope database, WAL and shared-memory file.
    public func sizeOnDisk() -> Int {
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Forgets one session's records and window.
    public func clear(scope: String, sessionId: String) throws {
        let handle = try database(scope: scope)
        try deleteSession(handle, scope: scope, sessionId: sessionId)
        try? handle.execute("VACUUM")
    }

    /// The settings switch: everything, including the database files themselves.
    public func clearAll() throws {
        for handle in handles.values { handle.close() }
        handles.removeAll()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    public func close() {
        for handle in handles.values { handle.close() }
        handles.removeAll()
    }

    // MARK: - Row-level helpers

    func deleteSession(_ handle: SQLiteHandle, scope: String, sessionId: String) throws {
        try handle.run("DELETE FROM record WHERE scope = ? AND session_id = ?") { statement in
            statement.bind(1, scope)
            statement.bind(2, sessionId)
        }
        try handle.run("DELETE FROM session_state WHERE scope = ? AND session_id = ?") { statement in
            statement.bind(1, scope)
            statement.bind(2, sessionId)
        }
    }

    func removeSessions(_ handle: SQLiteHandle, scope: String, olderThan deadline: Double) throws -> Int {
        let doomed = try sessions(handle, scope: scope).filter { $0.opened < deadline }
        for session in doomed {
            try deleteSession(handle, scope: scope, sessionId: session.sessionId)
        }
        return doomed.count
    }

    func sessions(_ handle: SQLiteHandle, scope: String) throws -> [(scope: String, sessionId: String, opened: Double, bytes: Int)] {
        let statement = try handle.prepare(
            """
            SELECT s.session_id, s.last_opened,
                   COALESCE((SELECT SUM(LENGTH(payload)) FROM record r
                             WHERE r.scope = s.scope AND r.session_id = s.session_id), 0)
            FROM session_state s WHERE s.scope = ?
            """
        )
        defer { statement.finalize() }
        statement.bind(1, scope)
        var rows: [(scope: String, sessionId: String, opened: Double, bytes: Int)] = []
        while try statement.step() {
            rows.append((scope: scope, sessionId: statement.string(0) ?? "", opened: statement.double(1), bytes: statement.int(2)))
        }
        return rows
    }

    /// Path components are host-chosen strings; reduce them so one can never
    /// escape the directory. The rule lives in `PathSlug` — one implementation for
    /// all three caches (constitution VI/VII.3).
    public static func slug(_ value: String) -> String {
        PathSlug.slug(value)
    }
}
