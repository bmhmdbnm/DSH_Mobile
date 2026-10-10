import Foundation
import GRDB

/// T024：用户输入全量灌库（spec 009「用户输入全量入库」/ tasks T024）。
///
/// 冷启动后的低优先级后台任务：逐会话走 `_link/sessionFind` 浏览模式
/// （roles=['me']、无关键词，游标分页，newest first），把 snippet 灌进
/// `user_inputs` 表 + FTS5，「我问过的」列表与搜索因此零网络。
///
/// 去重策略（账本在 `user_input_state` 表）：
/// - 距上次灌库 < `freshWindow`（24h）且会话 lastSeq 没有变大 → 整会话跳过；
/// - lastSeq 变大了 → 增量补拉：从最新一页开始，遇到「整页都已入库」即停
///   （浏览模式按 seq 从新到旧扫，页内最大 seq ≤ 本地已知最大 seq 时，
///   更早的一定都在库里）。
/// - 灌库是缓存行为，失败由调用方静默跳过（取用失败即拉取兜底）。
public struct UserInputBackfiller: Sendable {

    /// 一页浏览结果的网络面：`cursor == nil` 表示从最新开始。
    public typealias PageFetch = @Sendable (_ cursor: String?) async throws -> HistorySearchValue

    /// 某会话的灌库账本（`user_input_state` 的投影）。
    public struct State: Sendable, Equatable {
        public let pulledAt: Date
        public let lastSeq: Int

        public init(pulledAt: Date, lastSeq: Int) {
            self.pulledAt = pulledAt
            self.lastSeq = lastSeq
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// 24h 内灌过且 lastSeq 没变，整会话跳过。
        case skippedFresh
        /// 拉了 `pages` 页，入库 `rows` 条（含幂等 replace）。
        case pulled(pages: Int, rows: Int)
    }

    let store: MessageStore
    let now: @Sendable () -> Date
    /// 距上次灌库多久内算「新鲜」。默认 24h，测试可注入。
    let freshWindow: TimeInterval
    /// 单会话最多拉多少页（防失控；浏览模式一页 200 条，正常会话几页就到底）。
    let maxPages: Int

    public init(store: MessageStore, now: @escaping @Sendable () -> Date = Date.init,
                freshWindow: TimeInterval = 24 * 3600, maxPages: Int = 100) {
        self.store = store
        self.now = now
        self.freshWindow = freshWindow
        self.maxPages = maxPages
    }

    /// 灌一个会话。`lastSeq` 是列表已知的最新游标（host asOfSeq 或磁盘 newestSeq）。
    public func backfill(
        scope: String, sessionId: String, lastSeq: Int, fetch: PageFetch
    ) async throws -> Outcome {
        let previous = try await store.userInputState(scope: scope, sessionId: sessionId)
        if let previous,
           now().timeIntervalSince(previous.pulledAt) < freshWindow,
           previous.lastSeq >= lastSeq {
            return .skippedFresh
        }
        // 增量锚点：此前灌过的最大 seq。全新会话为 nil（拉到 hasMore=false 为止）。
        let knownMax = try await store.maxUserInputSeq(scope: scope, sessionId: sessionId)
        var cursor: String?
        var pages = 0
        var rows = 0
        while true {
            let value = try await fetch(cursor)
            pages += 1
            if !value.hits.isEmpty {
                rows += value.hits.count
                try await store.upsertUserInputs(value.hits.map { hit in
                    MessageStore.UserInputRow(
                        scope: scope, sessionId: sessionId, seq: hit.seq, snippet: hit.snippet)
                })
                // 增量停止：浏览模式按 seq 从新到旧连续扫，页里出现已入库的
                // seq 说明已扫到上次灌过的地盘，更早的必然都在（upsert 幂等，
                // 重叠这几条 replace 一遍也无妨）。零命中页不带这个信号，继续翻。
                if let knownMax, value.hits.contains(where: { $0.seq <= knownMax }) {
                    break
                }
            }
            guard value.hasMore, let next = value.cursor, pages < maxPages else { break }
            cursor = next
        }
        try await store.saveUserInputState(
            scope: scope, sessionId: sessionId,
            state: State(pulledAt: now(), lastSeq: max(lastSeq, previous?.lastSeq ?? 0)))
        return .pulled(pages: pages, rows: rows)
    }
}

extension MessageStore {

    /// 读某会话的灌库账本；nil = 从没灌过。
    public func userInputState(
        scope: String, sessionId: String
    ) async throws -> UserInputBackfiller.State? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT pulled_at, last_seq FROM user_input_state
                WHERE scope = ? AND session_id = ?
                """, arguments: [scope, sessionId]).map { row in
                UserInputBackfiller.State(
                    pulledAt: Date(timeIntervalSince1970: row["pulled_at"]),
                    lastSeq: row["last_seq"])
            }
        }
    }

    /// 写灌库账本（整会话灌完或增量补拉完成后各记一次）。
    public func saveUserInputState(
        scope: String, sessionId: String, state: UserInputBackfiller.State
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO user_input_state (scope, session_id, pulled_at, last_seq)
                VALUES (?, ?, ?, ?)
                """, arguments: [scope, sessionId,
                                 state.pulledAt.timeIntervalSince1970, state.lastSeq])
        }
    }

    /// 本地已灌的最大 seq（增量补拉的锚点）；nil = 空库。
    public func maxUserInputSeq(scope: String, sessionId: String) async throws -> Int? {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(seq) FROM user_inputs WHERE scope = ? AND session_id = ?
                """, arguments: [scope, sessionId])
        }
    }
}
