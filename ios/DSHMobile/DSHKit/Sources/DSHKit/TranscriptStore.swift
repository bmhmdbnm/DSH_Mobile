import Foundation

/// Durable history for one phone: the records it has already read, plus where
/// each session's window currently starts and ends.
///
/// Replaces `SessionTranscriptCache`, whose whole-file JSON rewrite happened on
/// the main actor and cost O(records) per page — measured at roughly 7MB of
/// encoding per backward page at the old 3000-record cap (spec 007 research §7).
/// Here a page costs O(new records): an indexed `INSERT` batch, and a window read
/// is an indexed range query. The write path runs in this actor, so nothing about
/// it touches the main thread.
///
/// One database per computer (`scope`), because that is how the old files were
/// laid out and it keeps "forget this computer" a directory operation.
public actor TranscriptStore {

    /// A session nobody opened for this long is dropped (spec FR-034). The clock
    /// starts at the last *open* — not at the last write — so a session that only
    /// streams in the background still ages out if the reader never looks at it.
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Total bytes the cache may occupy before the least recently opened session
    /// is dropped. Same value the JSON cache used.
    public static let budgetBytes = 40 * 1024 * 1024

    /// What is known about one session without reading its records.
    public struct SessionState: Sendable, Equatable {
        public let oldestSeq: Int?
        public let newestSeq: Int?
        /// Host-authoritative "there is older history". Never written by a failure.
        public let hasMore: Bool
        public let lastOpened: Date
    }

    // Internal rather than private: the housekeeping half lives in
    // `TranscriptStore+Housekeeping.swift` (one file per concern, and both stay
    // under the project's size limit). Nothing outside DSHKit can see them.
    let root: URL
    let now: @Sendable () -> Date
    let budgetBytes: Int
    let maxAge: TimeInterval
    let fileManager: FileManager
    var handles: [String: SQLiteHandle] = [:]

    public init(
        root: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        budgetBytes: Int = TranscriptStore.budgetBytes,
        maxAge: TimeInterval = TranscriptStore.maxAge,
        fileManager: FileManager = .default
    ) {
        let base = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root = base.appendingPathComponent("transcripts", isDirectory: true)
        self.now = now
        self.budgetBytes = budgetBytes
        self.maxAge = maxAge
        self.fileManager = fileManager
    }

    // MARK: - Writing

    /// Stores records and updates the session's window in one transaction.
    ///
    /// `hasMore` comes from the Host and is the only thing allowed to say "no
    /// older history"; a failed or trimmed page must never write it.
    public func append(
        scope: String,
        sessionId: String,
        records: [SessionRecord],
        hasMore: Bool,
        openedAt: Date? = nil
    ) throws {
        guard !records.isEmpty else { return }
        let database = try database(scope: scope)
        let ordered = records.sorted { $0.event.seq < $1.event.seq }
        try database.execute("BEGIN IMMEDIATE")
        do {
            try insert(ordered, scope: scope, sessionId: sessionId, database: database)
            try upsertState(scope: scope, sessionId: sessionId, records: ordered,
                            hasMore: hasMore, openedAt: openedAt ?? now(), database: database)
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    /// 一小段键值（`meta` 表）：用来记"这个会话的搜索缓冲落盘时覆盖了哪一段"。
    ///
    /// 为什么要记：搜索缓冲和已加载窗口存在**同一张 `record` 表**里，光看表分不出哪些是缓冲。
    /// 原来的恢复启发式（"比窗口最老那条还老"）在窗口恰好覆盖了缓冲时会什么都找不到——
    /// 冷启动后"只看我的提问"于是只剩窗口那一段（2026-10-08 T069 实测）。
    public func setMeta(_ key: String, _ value: String, scope: String) throws {
        let database = try database(scope: scope)
        try database.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") { statement in
            statement.bind(1, key)
            statement.bind(2, value)
        }
    }

    public func meta(_ key: String, scope: String) throws -> String? {
        let database = try database(scope: scope)
        let statement = try database.prepare("SELECT value FROM meta WHERE key = ?")
        defer { statement.finalize() }
        statement.bind(1, key)
        guard try statement.step(), let value = statement.string(0) else { return nil }
        return value
    }

    /// Records that the reader opened this session (the archive clock, FR-034).
    public func touch(scope: String, sessionId: String, at date: Date? = nil) throws {
        let database = try database(scope: scope)
        try database.run(
            "UPDATE session_state SET last_opened = MAX(last_opened, ?) WHERE scope = ? AND session_id = ?"
        ) { statement in
            statement.bind(1, (date ?? now()).timeIntervalSince1970)
            statement.bind(2, scope)
            statement.bind(3, sessionId)
        }
    }

    private func insert(_ records: [SessionRecord], scope: String, sessionId: String,
                        database: SQLiteHandle) throws {
        let encoder = JSONEncoder()
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO record (scope, session_id, seq, kind, payload) VALUES (?, ?, ?, ?, ?)"
        )
        defer { statement.finalize() }
        for record in records {
            let payload: Data
            do {
                payload = try encoder.encode(record)
            } catch {
                throw TranscriptStoreError.decode(String(describing: error))
            }
            statement.reset()
            statement.bind(1, scope)
            statement.bind(2, sessionId)
            statement.bind(3, record.event.seq)
            statement.bind(4, record.event.type)
            statement.bind(5, payload)
            try statement.step()
        }
    }

    private func upsertState(scope: String, sessionId: String, records: [SessionRecord],
                             hasMore: Bool, openedAt: Date, database: SQLiteHandle) throws {
        let known = try state(scope: scope, sessionId: sessionId, database: database)
        let oldest = [known?.oldestSeq, records.first?.event.seq].compactMap { $0 }.min()
        let newest = [known?.newestSeq, records.last?.event.seq].compactMap { $0 }.max()
        // `has_more` moves only on an append that carries an authoritative value;
        // otherwise the previous answer stands.
        let more = hasMore
        try database.run(
            """
            INSERT INTO session_state (scope, session_id, oldest_seq, newest_seq, has_more, last_opened)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (scope, session_id) DO UPDATE SET
              oldest_seq = excluded.oldest_seq,
              newest_seq = excluded.newest_seq,
              has_more = excluded.has_more,
              last_opened = MAX(session_state.last_opened, excluded.last_opened)
            """
        ) { statement in
            statement.bind(1, scope)
            statement.bind(2, sessionId)
            if let oldest { statement.bind(3, oldest) } else { statement.bindNull(3) }
            if let newest { statement.bind(4, newest) } else { statement.bindNull(4) }
            statement.bind(5, more ? 1 : 0)
            statement.bind(6, openedAt.timeIntervalSince1970)
        }
    }

    // MARK: - Reading

    /// The newest `limit` records strictly older than `before`, ascending.
    ///
    /// This is what makes a sliding memory window cheap: a session dropped from
    /// memory is read back by seq, with no network involved (spec FR-035).
    public func loadWindow(scope: String, sessionId: String, before: Int, limit: Int) throws -> [SessionRecord] {
        guard limit > 0 else { return [] }
        let statement = try database(scope: scope).prepare(
            """
            SELECT payload FROM record
            WHERE scope = ? AND session_id = ? AND seq < ?
            ORDER BY seq DESC LIMIT ?
            """
        )
        defer { statement.finalize() }
        statement.bind(1, scope)
        statement.bind(2, sessionId)
        statement.bind(3, before)
        statement.bind(4, limit)
        return try decode(statement).reversed()
    }

    /// A window around one seq, used to jump to a search hit (spec FR-011).
    public func loadAround(scope: String, sessionId: String, seq: Int,
                           before: Int, after: Int) throws -> [SessionRecord] {
        let database = try database(scope: scope)
        let older = try window(database, scope: scope, sessionId: sessionId, seq: seq, before: before, after: after)
        return older
    }

    private func window(_ database: SQLiteHandle, scope: String, sessionId: String,
                        seq: Int, before: Int, after: Int) throws -> [SessionRecord] {
        var records: [SessionRecord] = []
        if before > 0 {
            let statement = try database.prepare(
                "SELECT payload FROM record WHERE scope = ? AND session_id = ? AND seq <= ? ORDER BY seq DESC LIMIT ?"
            )
            defer { statement.finalize() }
            statement.bind(1, scope)
            statement.bind(2, sessionId)
            statement.bind(3, seq)
            statement.bind(4, before + 1)
            records = try decode(statement).reversed()
        }
        if after > 0 {
            let statement = try database.prepare(
                "SELECT payload FROM record WHERE scope = ? AND session_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?"
            )
            defer { statement.finalize() }
            statement.bind(1, scope)
            statement.bind(2, sessionId)
            statement.bind(3, seq)
            statement.bind(4, after)
            records.append(contentsOf: try decode(statement))
        }
        return records
    }

    private func decode(_ statement: SQLiteStatement) throws -> [SessionRecord] {
        let decoder = JSONDecoder()
        var records: [SessionRecord] = []
        while try statement.step() {
            let payload = statement.data(0)
            do {
                records.append(try decoder.decode(SessionRecord.self, from: payload))
            } catch {
                throw TranscriptStoreError.decode(String(describing: error))
            }
        }
        return records
    }

    public func state(scope: String, sessionId: String) throws -> SessionState? {
        try state(scope: scope, sessionId: sessionId, database: try database(scope: scope))
    }

    private func state(scope: String, sessionId: String, database: SQLiteHandle) throws -> SessionState? {
        let statement = try database.prepare(
            "SELECT oldest_seq, newest_seq, has_more, last_opened FROM session_state WHERE scope = ? AND session_id = ?"
        )
        defer { statement.finalize() }
        statement.bind(1, scope)
        statement.bind(2, sessionId)
        guard try statement.step() else { return nil }
        return SessionState(
            oldestSeq: statement.optionalInt(0),
            newestSeq: statement.optionalInt(1),
            hasMore: statement.bool(2),
            lastOpened: Date(timeIntervalSince1970: statement.double(3))
        )
    }
}
