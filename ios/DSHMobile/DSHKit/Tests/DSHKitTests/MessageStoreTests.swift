@testable import DSHKit
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
                        text: String = "hello") -> SessionRecord {
        // SessionEvent 的 memberwise init 是 internal（models 按解码入口设计），
        // 测试沿用 007 的做法：从 JSON 解码构造。
        let json = #"{"type":"\#(type)","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)"}}"#
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
}
