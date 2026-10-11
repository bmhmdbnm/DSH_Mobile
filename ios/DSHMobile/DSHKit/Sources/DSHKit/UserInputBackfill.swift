import Foundation
import GRDB

/// T033：用户输入全量灌库（三表终局，spec 009 data-model v3）。
///
/// 冷启动后的低优先级后台任务：逐会话走 `_link/sessionWindow` 的
/// `roles:['me']` 过滤分页（连接器能力 `history-role-filter`），把**完整
/// SessionRecord** 经 `applyWrites` 同一幂等路径写进 `record` 表——不再写
/// 独立的 user_inputs 摘要表（摘要没有 source，是三表模型的脏数据来源）。
///
/// 降级语义：连接器没有 `history-role-filter` 时**跳过整个回填**（不回退到
/// 浏览模式写摘要——那会污染新模型），由调用方在探针里留痕，等连接器升级。
///
/// 账本（`meta` 键值表，key=`uinput.sync.<scope>/<sid>`，
/// value=`游标:lastSeq:时间戳`）：
/// - 距上次灌库 < `freshWindow`（24h）且会话 lastSeq 没有变大 → 整会话跳过；
/// - lastSeq 变大了 → 增量补拉：从最新一页开始，页里出现已入库的 seq 即停；
/// - 拉到 `hasMore=false`（日志最老）才算灌全，置
///   `session_state.user_inputs_synced_at` 完整性标记（data-model v3）。
public struct UserInputBackfiller: Sendable {

    /// 一页窗口拉取：`before == nil` 表示从最新开始（开区间上界 .max）。
    public typealias PageFetch = @Sendable (_ before: Int?) async throws -> HistoryWindowValue

    /// 某会话的灌库账本（meta 键值的投影）。`resumeCursor` 是上次没灌完时的
    /// 续拉锚点（下一页的 before），灌全了为 nil。
    public struct State: Sendable, Equatable {
        public let pulledAt: Date
        public let lastSeq: Int
        public let resumeCursor: Int?

        public init(pulledAt: Date, lastSeq: Int, resumeCursor: Int? = nil) {
            self.pulledAt = pulledAt
            self.lastSeq = lastSeq
            self.resumeCursor = resumeCursor
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// 24h 内灌过且 lastSeq 没变，整会话跳过。
        case skippedFresh
        /// 连接器没有 `history-role-filter`：跳过（不写任何东西），等升级。
        case unsupported
        /// 拉了 `pages` 页，入库 `rows` 条（含幂等 replace）。
        case pulled(pages: Int, rows: Int)
    }

    let store: MessageStore
    let now: @Sendable () -> Date
    /// 连接器是否支持 `_link/sessionWindow` 的 roles 过滤。
    let roleFilterSupported: Bool
    /// 距上次灌库多久内算「新鲜」。默认 24h，测试可注入。
    let freshWindow: TimeInterval
    /// 单会话最多拉多少页（防失控）。
    let maxPages: Int

    public init(store: MessageStore, now: @escaping @Sendable () -> Date = Date.init,
                roleFilterSupported: Bool = true,
                freshWindow: TimeInterval = 24 * 3600, maxPages: Int = 100) {
        self.store = store
        self.now = now
        self.roleFilterSupported = roleFilterSupported
        self.freshWindow = freshWindow
        self.maxPages = maxPages
    }

    /// 灌一个会话。`lastSeq` 是列表已知的最新游标（host asOfSeq 或磁盘 newestSeq）。
    public func backfill(
        scope: String, sessionId: String, lastSeq: Int, fetch: PageFetch
    ) async throws -> Outcome {
        // 降级：老连接器给不出归类过的完整记录，浏览模式的摘要写进 record 就是
        // 脏数据（没有 source）。宁可不灌，等连接器升级。
        guard roleFilterSupported else { return .unsupported }
        let previous = try await store.userInputSyncState(scope: scope, sessionId: sessionId)
        if let previous,
           now().timeIntervalSince(previous.pulledAt) < freshWindow,
           previous.lastSeq >= lastSeq {
            return .skippedFresh
        }
        // 增量锚点：此前灌过的最大 seq（record 表里的 me 子集）。全新会话为 0。
        let knownMax = try await store.maxUserInputSeq(scope: scope, sessionId: sessionId) ?? 0
        var before: Int? = previous?.resumeCursor
        var pages = 0
        var rows = 0
        var completed = false
        // 没灌全时的续拉锚点：下一页的 before（取当前页最老返回记录的 seq；
        // 空页给不出新锚点，停在原锚点重拉，不劣化）。
        var resume: Int? = before
        while true {
            let value = try await fetch(before)
            pages += 1
            if !value.records.isEmpty {
                rows += value.records.count
                try await store.applyWrites([
                    .upsertRecords(scope: scope, sessionId: sessionId, records: value.records),
                ])
                // 增量停止：窗口按 seq 从新到旧扫，页里出现已入库的 seq 说明
                // 已扫到上次灌过的地盘（upsert 幂等，重叠这几条 replace 无妨）。
                if value.records.contains(where: { $0.event.seq <= knownMax }) {
                    completed = true
                    break
                }
            }
            resume = value.startSeq ?? before
            guard value.hasMore, let oldest = value.startSeq, pages < maxPages else {
                // hasMore=false 才算到日志最老；空页（本窗口全是被过滤行）给不出
                // 续拉游标，停在未灌全状态，下次冷启动从 resumeCursor 再试。
                completed = !value.hasMore
                break
            }
            before = oldest
        }
        try await store.saveUserInputSyncState(
            scope: scope, sessionId: sessionId,
            state: State(pulledAt: now(), lastSeq: max(lastSeq, previous?.lastSeq ?? 0),
                         resumeCursor: completed ? nil : resume))
        if completed {
            try await store.setUserInputsSyncedAt(scope: scope, sessionId: sessionId, at: now())
        }
        return .pulled(pages: pages, rows: rows)
    }
}

extension MessageStore {

    /// meta 键：某会话的灌库账本（internal：MessageStore+Maintenance 的 clear 也用）。
    static func syncKey(scope: String, sessionId: String) -> String {
        "uinput.sync.\(scope)/\(sessionId)"
    }

    /// 读某会话的灌库账本；nil = 从没灌过。value 形如 `游标:lastSeq:时间戳`
    /// （游标为 `-` 表示已灌全）。
    public func userInputSyncState(
        scope: String, sessionId: String
    ) async throws -> UserInputBackfiller.State? {
        try await pool.read { db in
            guard let value = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Self.syncKey(scope: scope, sessionId: sessionId)])
            else { return nil }
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let lastSeq = Int(parts[1]),
                  let timestamp = Double(parts[2])
            else { return nil }  // 账本损坏当作没灌过（缓存语义，重灌即可）
            return UserInputBackfiller.State(
                pulledAt: Date(timeIntervalSince1970: timestamp),
                lastSeq: lastSeq,
                resumeCursor: Int(parts[0]))
        }
    }

    /// 写灌库账本（整会话灌完或增量补拉完成后各记一次）。
    public func saveUserInputSyncState(
        scope: String, sessionId: String, state: UserInputBackfiller.State
    ) async throws {
        let cursor = state.resumeCursor.map(String.init) ?? "-"
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                arguments: [Self.syncKey(scope: scope, sessionId: sessionId),
                            "\(cursor):\(state.lastSeq):\(state.pulledAt.timeIntervalSince1970)"])
        }
    }

    /// 本地已灌的最大 seq（增量补拉的锚点），归类口径与 `userInputRecords` 一致；
    /// nil = 空库。
    public func maxUserInputSeq(scope: String, sessionId: String) async throws -> Int? {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(seq) FROM record
                WHERE scope = ? AND session_id = ? AND role = 'me'
                  AND COALESCE(source_kind, 'user') = 'user'
                  AND (source_id IS NULL OR source_id NOT LIKE 'agent-%')
                """, arguments: [scope, sessionId])
        }
    }

    /// 完整性标记：该会话的用户输入子集已灌全（data-model v3，
    /// 「子集是否灌全看这个标记，不能从表内容推断」）。
    public func setUserInputsSyncedAt(scope: String, sessionId: String, at date: Date) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE session_state SET user_inputs_synced_at = ?
                WHERE scope = ? AND session_id = ?
                """, arguments: [date.timeIntervalSince1970, scope, sessionId])
        }
    }

    /// 读完整性标记（测试与读侧用）；nil = 未灌全/没灌过。
    public func userInputsSyncedAt(scope: String, sessionId: String) async throws -> Date? {
        try await pool.read { db in
            try Double.fetchOne(db, sql: """
                SELECT user_inputs_synced_at FROM session_state
                WHERE scope = ? AND session_id = ?
                """, arguments: [scope, sessionId]).map { Date(timeIntervalSince1970: $0) }
        }
    }
}
