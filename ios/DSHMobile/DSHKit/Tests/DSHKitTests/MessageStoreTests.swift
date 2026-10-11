@testable import DSHKit
import GRDB
import XCTest

/// GRDB 磁盘层（spec 009 data-model / tasks T004/T005）：
/// 建库、区间读写、角色映射、pending 确认替换、列表聚合、用户输入 FTS。
final class MessageStoreTests: XCTestCase {

    private var directory: URL!
    private var store: MessageStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-store-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ seq: Int, type: String = "assistant/message",
                        text: String = "hello", source: String? = nil) -> SessionRecord {
        // SessionEvent 的 memberwise init 是 internal（models 按解码入口设计），
        // 测试沿用 007 的做法：从 JSON 解码构造。
        let sourceJSON = source.map { ",\"source\":\($0)" } ?? ""
        let json = #"{"type":"\#(type)","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)"\#(sourceJSON)}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    private func upsert(_ records: [SessionRecord], session: String = "s1") async throws {
        try await store.applyWrites([
            .upsertRecords(scope: "mac", sessionId: session, records: records)
        ])
    }

    func testRoundTripByRange() async throws {
        try await upsert([record(1), record(2), record(3), record(4)])
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 2...3)
        XCTAssertEqual(records.map(\.event.seq), [2, 3])
    }

    func testWindowBeforeReturnsAscending() async throws {
        try await upsert((1...10).map { record($0) })
        let page = try await store.windowBefore(scope: "mac", sessionId: "s1", seq: 8, limit: 3)
        XCTAssertEqual(page.map(\.event.seq), [5, 6, 7])
    }

    func testRoleMappingFollowsConnector() async throws {
        try await upsert([
            record(1, type: "user/message"),
            record(2, type: "assistant/message"),
            record(3, type: "tool/call"),
        ])
        // role 列本身不进投影，用 user_inputs 之外的校验方式：直接查库。
        let roles = try await store.rolesForTesting(scope: "mac", sessionId: "s1")
        XCTAssertEqual(roles, ["me", "agent", "tool"])
    }

    /// 发送链路（spec US5）：pending 先入，确认后原地替换，库里只剩一条 sent。
    func testPendingConfirmReplacesInPlace() async throws {
        try await store.applyWrites([
            .upsertPending(scope: "mac", sessionId: "s1", clientId: "c-1", record: record(5, type: "user/message")),
        ])
        try await store.applyWrites([
            .confirmPending(scope: "mac", sessionId: "s1", clientId: "c-1", record: record(5, type: "user/message")),
        ])
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 1...10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event.seq, 5)
    }

    func testSessionStatesAggregateForColdStart() async throws {
        try await upsert([record(1, text: "first"), record(2, text: "second")], session: "s1")
        try await upsert([record(1, text: "other")], session: "s2")
        let states = try await store.sessionStates(scope: "mac")
        XCTAssertEqual(states.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(states[0].newestSeq, 2)
        XCTAssertEqual(states[0].lastSnippet, "second")
        XCTAssertEqual(states[0].hasMore, true)  // 默认 true：失败永不写 hasMore
    }

    /// 区间集随会话持久化（data-model ranges_json）：冷启动预取判定靠它。
    func testRangesRoundTrip() async throws {
        try await upsert([record(1)])
        var ranges = RangeIndex()
        ranges.insert(100...200)
        ranges.insert(400...450)
        try await store.saveRanges(scope: "mac", sessionId: "s1", ranges: ranges)
        let states = try await store.sessionStates(scope: "mac")
        XCTAssertEqual(states.first?.ranges.spans, [.init(100, 200), .init(400, 450)])
    }

    func testUserInputsInsertAndSearch() async throws {
        try await store.upsertUserInputs([
            .init(scope: "mac", sessionId: "s1", seq: 10, snippet: "怎么部署到服务器"),
            .init(scope: "mac", sessionId: "s1", seq: 20, snippet: "写个单元测试"),
            .init(scope: "mac", sessionId: "s2", seq: 5, snippet: "部署文档在哪"),
        ])
        let all = try await store.userInputs(scope: "mac")
        XCTAssertEqual(all.count, 3)
        let hits = try await store.searchUserInputs(scope: "mac", query: "部署")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.seq), [10, 5])
    }

    // MARK: - T032：source 列

    /// 写入路径从 data.source 提取 source_kind/source_id；缺省（老数据形态）留空，
    /// 查询侧按 'user' 兼容（data-model.md v3）。
    func testSourceColumnsWrittenOnInsert() async throws {
        try await upsert([
            record(1, type: "user/message", source: #"{"kind":"plugin","rpcId":"rpc-9"}"#),
            record(2, type: "user/message", source: #"{"kind":"user","rpcId":"rpc-1"}"#),
            record(3, type: "user/message"),  // 缺省：无 source 字段
        ])
        let sources = try await store.sourcesForTesting(scope: "mac", sessionId: "s1")
        XCTAssertEqual(sources.map(\.0), ["plugin", "user", nil])
        XCTAssertEqual(sources.map(\.1), ["rpc-9", "rpc-1", nil])
    }

    /// 「我问过的」候选（T034 先用于测试）：只要用户本人发的，排除 plugin 与 agent- 代发。
    func testUserInputRecordsExcludePluginAndAgentRelay() async throws {
        try await upsert([
            record(1, type: "user/message", source: #"{"kind":"plugin","rpcId":"rpc-9"}"#),
            record(2, type: "user/message", source: #"{"kind":"user","rpcId":"agent-42"}"#),
            record(3, type: "user/message", source: #"{"kind":"user","rpcId":"rpc-1"}"#),
            record(4, type: "user/message"),  // 缺省按 'user'
            record(5, type: "assistant/message"),
        ])
        let records = try await store.userInputRecords(scope: "mac")
        XCTAssertEqual(records.map(\.event.seq), [3, 4])
    }

    /// v2→v3 迁移：老行按 payload 回填，解析不出/缺 source 的按 'user'。
    func testMigrationBackfillsSourceOnOldRows() async throws {
        let url = directory.appendingPathComponent("old.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldPool = try DatabasePool(path: url.path)
        // 预先构造好 payload（write 闭包是 @Sendable，不抓 self）。
        let payloads = try (1...2).map { seq -> Data in
            let source = seq == 1 ? #"{"kind":"plugin","rpcId":"rpc-7"}"# : nil
            return try JSONEncoder().encode(self.record(seq, type: "user/message", source: source))
        }
        try await oldPool.write { db in
            try db.execute(sql: """
                CREATE TABLE record (
                  scope TEXT NOT NULL, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
                  kind TEXT NOT NULL, role TEXT NOT NULL, payload BLOB NOT NULL,
                  byte_size INTEGER NOT NULL, client_id TEXT,
                  status TEXT NOT NULL DEFAULT 'sent',
                  PRIMARY KEY (scope, session_id, seq));
                """)
            for (index, payload) in payloads.enumerated() {
                try db.execute(sql: """
                    INSERT INTO record (scope, session_id, seq, kind, role, payload, byte_size, status)
                    VALUES ('mac', 's1', ?, 'user/message', 'me', ?, ?, 'sent')
                    """, arguments: [index + 1, payload, payload.count])
            }
            // 解析不出的脏 payload：回填必须兜底 'user'。
            try db.execute(sql: """
                INSERT INTO record (scope, session_id, seq, kind, role, payload, byte_size, status)
                VALUES ('mac', 's1', 3, 'user/message', 'me', X'DEAD', 2, 'sent')
                """)
        }
        try await oldPool.close()

        let migrated = try MessageStore(path: url)
        let sources = try await migrated.sourcesForTesting(scope: "mac", sessionId: "s1")
        XCTAssertEqual(sources.map(\.0), ["plugin", "user", "user"])
        XCTAssertEqual(sources.map(\.1), ["rpc-7", nil, nil])
    }
}
