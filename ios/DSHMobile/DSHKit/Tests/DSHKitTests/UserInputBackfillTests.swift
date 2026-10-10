@testable import DSHKit
import XCTest

/// 测试用可拨动时钟（`@Sendable` 闭包捕获需要 Sendable；测试串行执行，无竞争）。
private final class MutableClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// 造一页浏览结果：seq 降序，cursor 指向下一段。
private func browsePage(_ seqs: [Int], cursor: String?, hasMore: Bool) -> HistorySearchValue {
    HistorySearchValue(
        hits: seqs.map { HistorySearchHit(seq: $0, role: "me", snippet: "问题\($0)",
                                          highlightStart: 0, highlightLength: 0) },
        cursor: cursor, hasMore: hasMore, source: "scan")
}

/// T024 用户输入灌库（spec 009「用户输入全量入库」）：
/// 全量首灌、24h 去重跳过、lastSeq 变大后的增量补拉（遇已知 seq 即停）、账本持久化。
final class UserInputBackfillTests: XCTestCase {

    private var directory: URL!
    private var store: MessageStore!
    private var clock: MutableClock!
    private var backfiller: UserInputBackfiller!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-input-backfill-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
        clock = MutableClock()
        let clockRef = clock!
        backfiller = UserInputBackfiller(store: store, now: { clockRef.date })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstBackfillPullsAllPages() async throws {
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { cursor in
            cursor == nil
                ? browsePage([100, 90, 80], cursor: "40", hasMore: true)
                : browsePage([40, 30], cursor: nil, hasMore: false)
        }
        XCTAssertEqual(outcome, .pulled(pages: 2, rows: 5))
        let all = try await store.userInputs(scope: "mac")
        XCTAssertEqual(all.map(\.seq), [30, 40, 80, 90, 100])
        let hits = try await store.searchUserInputs(scope: "mac", query: "问题9")
        XCTAssertEqual(hits.map(\.seq), [90])
        let state = try await store.userInputState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.lastSeq, 100)
    }

    func testSkipsWhenFreshAndLastSeqUnchanged() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            browsePage([100], cursor: nil, hasMore: false)
        }
        clock.date = clock.date.addingTimeInterval(3600) // 1h 后，仍在 24h 新鲜窗口内
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            XCTFail("24h 内且 lastSeq 没变，不该发请求")
            return browsePage([], cursor: nil, hasMore: false)
        }
        XCTAssertEqual(outcome, .skippedFresh)
    }

    func testRepullsWhenStale() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            browsePage([100], cursor: nil, hasMore: false)
        }
        clock.date = clock.date.addingTimeInterval(25 * 3600) // 超过 24h：即使 lastSeq 没变也重灌
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            browsePage([100], cursor: nil, hasMore: false)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 1))
    }

    func testIncrementalStopsAtKnownSeq() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            browsePage([100, 90, 80], cursor: nil, hasMore: false)
        }
        clock.date = clock.date.addingTimeInterval(25 * 3600)
        // lastSeq 涨到 130：只补 130/120/110，页里碰到已入库的 100 就停（不再翻页）。
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 130) { cursor in
            XCTAssertNil(cursor, "增量补拉一页就该停，不该继续翻")
            return browsePage([130, 120, 110, 100], cursor: "70", hasMore: true)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 4))
        let all = try await store.userInputs(scope: "mac")
        XCTAssertEqual(all.map(\.seq), [80, 90, 100, 110, 120, 130])
        let state = try await store.userInputState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.lastSeq, 130)
    }

    func testFailureLeavesStateUntouched() async throws {
        struct Boom: Error {}
        _ = try? await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            throw Boom()
        }
        let state = try await store.userInputState(scope: "mac", sessionId: "s1")
        XCTAssertNil(state, "失败的灌库不记账，下次冷启动还会重试")
    }
}
