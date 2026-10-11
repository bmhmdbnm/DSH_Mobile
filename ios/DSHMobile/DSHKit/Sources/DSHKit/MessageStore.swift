import Foundation
import GRDB

/// GRDB 版磁盘层（spec 009 research D1 / data-model）。
///
/// 定位：**纯缓存**，不是事实来源——崩丢由「取用失败即拉取」兜底（owner 已拍板），
/// 所以这里的写入全部来自内存层的批量队列（`PendingWriteQueue`），不追求实时。
/// 取代 007 的手写 `TranscriptStore`（T027 删除旧层）；旧库不迁移，从空库建 v2。
///
/// 并发：`DatabasePool`（WAL，多读一写）天然匹配「读多写少、单写者」；
/// 本 actor 只负责把我们自己的调用串行成一个域（宪法：层内一个串行域）。
public actor MessageStore {

    /// 一次落库变更（上行 pending / 下行记录共用）。
    public enum RecordChange: Sendable {
        /// 新到/更新的一批记录（同一 session）。
        case upsertRecords(scope: String, sessionId: String, records: [SessionRecord])
        /// 发送中的乐观记录（pending），`clientId` 是手机侧稳定身份。
        case upsertPending(scope: String, sessionId: String, clientId: String, record: SessionRecord)
        /// 服务端确认：pending 记录换成正式记录。
        case confirmPending(scope: String, sessionId: String, clientId: String, record: SessionRecord)
    }

    /// 列表页一行（session_state 的投影）。
    public struct SessionListEntry: Sendable, Equatable {
        public let sessionId: String
        public let oldestSeq: Int?
        public let newestSeq: Int?
        public let hasMore: Bool
        public let lastSnippet: String?
        public let unreadCount: Int
        public let lastOpened: Date
        /// 冷启动预取判定用的有效连续区间（spec §6），JSON 序列化存储。
        public let ranges: RangeIndex
    }

    /// 「我问过的」一行（user_inputs 的投影）。
    public struct UserInputRow: Sendable, Equatable {
        public let scope: String
        public let sessionId: String
        public let seq: Int
        public let snippet: String

        public init(scope: String, sessionId: String, seq: Int, snippet: String) {
            self.scope = scope
            self.sessionId = sessionId
            self.seq = seq
            self.snippet = snippet
        }
    }

    /// 传输类型 → 三角色（映射沿用连接器 `roleOf()`，spec「用户输入全量入库」）。
    public enum Role: String, Sendable {
        case me, agent, tool, other

        public init(eventType: String) {
            switch eventType {
            case "user/message": self = .me
            case "assistant/message": self = .agent
            case "tool/call", "tool/result": self = .tool
            default: self = .other
            }
        }
    }

    // internal 而非 private：读写半边在 MessageStore+Records.swift（职责拆分，
    // 两个文件都在 500 行以内），模块外不可见。
    let pool: DatabasePool
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - path: 数据库文件路径；默认 `<caches>/message-store/messages.sqlite3`。
    ///     测试传临时目录（宪法 III：不碰真实数据）。
    public init(path: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) throws {
        let url = path ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("message-store", isDirectory: true)
            .appendingPathComponent("messages.sqlite3")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        self.now = now
        try MessageStore.migrator.migrate(pool)
    }

    // MARK: - Schema（GRDB DatabaseMigrator：v2 建表，v3 加 source 列）

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v2") { db in try createSchemaV2(db) }
        migrator.registerMigration("v3") { db in try migrateToV3(db) }
        return migrator
    }()

    static func createSchemaV2(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS record (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              seq        INTEGER NOT NULL,
              kind       TEXT    NOT NULL,
              role       TEXT    NOT NULL,
              payload    BLOB    NOT NULL,
              byte_size  INTEGER NOT NULL,
              client_id  TEXT,
              status     TEXT    NOT NULL DEFAULT 'sent',
              PRIMARY KEY (scope, session_id, seq)
            );
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_state (
              scope        TEXT    NOT NULL,
              session_id   TEXT    NOT NULL,
              oldest_seq   INTEGER,
              newest_seq   INTEGER,
              has_more     INTEGER NOT NULL DEFAULT 1,
              last_opened  REAL    NOT NULL,
              last_snippet TEXT,
              unread_count INTEGER NOT NULL DEFAULT 0,
              ranges_json  TEXT    NOT NULL DEFAULT '[]',
              PRIMARY KEY (scope, session_id)
            );
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS user_inputs (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              seq        INTEGER NOT NULL,
              snippet    TEXT    NOT NULL,
              pulled_at  REAL    NOT NULL,
              PRIMARY KEY (scope, session_id, seq)
            );
            """)
        // T024 灌库去重账本：每会话记 pulled_at 与当时见到的 last_seq，
        // 24h 内且 lastSeq 没变就跳过（UserInputBackfiller 的判定依据）。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS user_input_state (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              pulled_at  REAL    NOT NULL,
              last_seq   INTEGER NOT NULL,
              PRIMARY KEY (scope, session_id)
            );
            """)
        // trigram：unicode61 不会切中文（整段当一个词），子串搜索会全空。
        // trigram 需要查询 ≥3 字符，短查询在读取侧降级 LIKE（见 searchUserInputs）。
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS user_inputs_fts
            USING fts5(snippet, content=user_inputs, content_rowid=rowid, tokenize='trigram');
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS user_inputs_ai AFTER INSERT ON user_inputs BEGIN
              INSERT INTO user_inputs_fts(rowid, snippet) VALUES (new.rowid, new.snippet);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS user_inputs_ad AFTER DELETE ON user_inputs BEGIN
              INSERT INTO user_inputs_fts(user_inputs_fts, rowid, snippet)
              VALUES ('delete', old.rowid, old.snippet);
            END;
            """)
    }

    /// v3（data-model.md v3 / tasks T032）：`record` 加 `source_kind`/`source_id`。
    /// 老行回填：payload 里 `data.source.kind` 能解析按解析值，解析不出或缺省按 `'user'`
    ///（与连接器侧同一兼容口径）；`source_id` 取 `data.source.rpcId`，缺省留空。
    static func migrateToV3(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE record ADD COLUMN source_kind TEXT")
        try db.execute(sql: "ALTER TABLE record ADD COLUMN source_id TEXT")
        let rows = try Row.fetchAll(db, sql: "SELECT rowid, payload FROM record")
        let decoder = JSONDecoder()
        for row in rows {
            guard let payload: Data = row["payload"],
                  let record = try? decoder.decode(SessionRecord.self, from: payload)
            else { continue }  // 解析不出的行留给下面的兜底 UPDATE 置 'user'
            let source = record.event.data["source"]
            try db.execute(
                sql: "UPDATE record SET source_kind = ?, source_id = ? WHERE rowid = ?",
                arguments: [source?["kind"]?.stringValue, source?["rpcId"]?.stringValue, row["rowid"]])
        }
        try db.execute(sql: "UPDATE record SET source_kind = 'user' WHERE source_kind IS NULL")
    }
}
