import DSHKit
import XCTest

/// 取页游标状态机（spec 007 T015/T016）：三态、失败可重试、禁止 failed→end、
/// 连续性判定、去重到空仍推进、单飞、到底终态。
@MainActor
final class TranscriptPagerTests: XCTestCase {


    /// Records how many times the pager actually waited, without waiting.
    private final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        func note() { lock.lock(); count += 1; lock.unlock() }
    }

    private func makePager(oldest: Int?, hasMore: Bool = true, sleeps: Sleeps = Sleeps(),
                           diagnostics: (@Sendable (TranscriptPager.Diagnostic) -> Void)? = nil) -> TranscriptPager {
        TranscriptPager(
            sessionId: "s1",
            oldestLoadedSeq: oldest,
            newestLoadedSeq: 1000,
            hasMore: hasMore,
            sleep: { _ in sleeps.note() },
            onDiagnostic: diagnostics
        )
    }

    func testSuccessAdvancesTheWindowAndStaysInMore() async {
        let pager = await makePager(oldest: 500)
        let outcome = await pager.loadOlder { _ in makeTestPage(440...499, hasMore: true) }
        XCTAssertEqual(outcome, .prepended(count: 60, oldestSeq: 440))
        let state = pager.currentState
        let oldest = pager.oldestLoadedSeq
        XCTAssertEqual(state, .more)
        XCTAssertEqual(oldest, 440)
    }

    func testHostSayingNoMoreEndsTheWindow() async {
        let pager = await makePager(oldest: 50)
        let outcome = await pager.loadOlder { _ in makeTestPage(1...49, hasMore: false) }
        XCTAssertEqual(outcome, .prepended(count: 49, oldestSeq: 1))
        let state = pager.currentState
        XCTAssertEqual(state, .end)
    }

    func testFailureIsRetriedThenSucceeds() async {
        let sleeps = Sleeps()
        let pager = await makePager(oldest: 500, sleeps: sleeps)
        let box = FailOnce(page: makeTestPage(440...499, hasMore: true))
        let outcome = await pager.loadOlder { _ in try box.next() }
        XCTAssertEqual(outcome, .prepended(count: 60, oldestSeq: 440))
        XCTAssertEqual(sleeps.count, 1, "只该等一次退避")
        let state = pager.currentState
        XCTAssertEqual(state, .more)
    }

    func testPersistentFailureBecomesFailedAndNeverEnd() async {
        let sleeps = Sleeps()
        let pager = await makePager(oldest: 500, sleeps: sleeps)
        struct Boom: Error {}
        let outcome = await pager.loadOlder { _ in throw Boom() }
        XCTAssertEqual(outcome, .failed("Boom()"))
        XCTAssertEqual(sleeps.count, 2, "最多重试两次（共三次尝试）")
        let state = pager.currentState
        XCTAssertNotEqual(state, .end, "失败绝不能被写成到底")
        if case .failed(let failure) = state {
            XCTAssertTrue(failure.retryable)
        } else {
            XCTFail("expected failed state, got \(state)")
        }
        let oldest = pager.oldestLoadedSeq
        XCTAssertEqual(oldest, 500, "失败不该移动窗口")
    }

    func testFailedStateCanBeRetriedByTheReader() async {
        let pager = await makePager(oldest: 500)
        struct Boom: Error {}
        _ = await pager.loadOlder { _ in throw Boom() }
        let outcome = await pager.loadOlder { _ in makeTestPage(440...499, hasMore: true) }
        XCTAssertEqual(outcome, .prepended(count: 60, oldestSeq: 440))
        let state = pager.currentState
        XCTAssertEqual(state, .more, "重试成功后回到可继续")
    }

    func testNonContiguousPageIsRetriedInsteadOfAccepted() async {
        let pager = await makePager(oldest: 500)
        // endSeq 498 而窗口底是 500：499 那一段不见了，必须拒绝而不是当作正常页。
        let outcome = await pager.loadOlder { _ in
            TranscriptPager.Page(records: (440...498).map(makeTestRecord), startSeq: 440, endSeq: 498, hasMore: true)
        }
        XCTAssertEqual(outcome, .failed("page was not contiguous: endSeq 498 does not abut the window at 499 (and no clamp was reported)"))
        let state = pager.currentState
        XCTAssertNotEqual(state, .end)
    }

    func testClampedPageFromATrimmedLogIsAccepted() async {
        let pager = await makePager(oldest: 5000)
        let outcome = await pager.loadOlder { _ in
            TranscriptPager.Page(records: (198...248).map(makeTestRecord), startSeq: 198, endSeq: 248,
                                 hasMore: false, clamped: true)
        }
        XCTAssertEqual(outcome, .prepended(count: 51, oldestSeq: 198))
        let state = pager.currentState
        XCTAssertEqual(state, .end, "宿主说日志已到开头")
    }

    func testAnEmptyPageIsAFailureNotTheEndOfTheLog() async {
        let pager = await makePager(oldest: 500)
        // 精确窗口通道不会回空页；真空页说明出了问题，必须当失败重试，绝不能记成"到底了"。
        let outcome = await pager.loadOlder { _ in
            TranscriptPager.Page(records: [], startSeq: 440, endSeq: 440, hasMore: true)
        }
        XCTAssertEqual(outcome, .failed("page was not contiguous: empty page"))
        let state = pager.currentState
        XCTAssertNotEqual(state, .end)
        let oldest = pager.oldestLoadedSeq
        XCTAssertEqual(oldest, 500, "失败不该移动窗口")
    }

    func testConcurrentLoadsAreRefusedNotQueued() async {
        let pager = await makePager(oldest: 500)
        let box = OutcomeBox()
        // 在第一次取页「在飞」期间再要一页：必须是 busy，而不是排进队列。
        let first = await pager.loadOlder { _ in
            let nested = await pager.loadOlder { _ in makeTestPage(380...439, hasMore: true) }
            await box.set(nested)
            return makeTestPage(440...499, hasMore: true)
        }
        let nested = await box.value
        XCTAssertEqual(nested, .busy)
        XCTAssertEqual(first, .prepended(count: 60, oldestSeq: 440))
    }

    func testEndIsTerminalForThisSession() async {
        let pager = await makePager(oldest: 10, hasMore: false)
        let calls = Counter()
        let outcome = await pager.loadOlder { _ in
            calls.bump()
            return makeTestPage(1...10, hasMore: false)
        }
        XCTAssertEqual(outcome, .endOfLog)
        XCTAssertEqual(calls.value, 0, "到底之后不该再发请求")
    }

    func testResetFromSnapshotMovesBothEdges() async {
        let pager = await makePager(oldest: 900)
        await pager.reset(oldestLoadedSeq: 120, newestLoadedSeq: 700, hasMore: true)
        let oldest = pager.oldestLoadedSeq
        let newest = pager.newestLoadedSeq
        XCTAssertEqual(oldest, 120)
        XCTAssertEqual(newest, 700)
    }

    func testDiagnosticsCarryEnoughToJudgeAPage() async {
        let box = DiagnosticBox()
        let pager = await makePager(oldest: 500) { box.append($0) }
        _ = await pager.loadOlder { _ in makeTestPage(440...499, hasMore: false) }
        let events = box.events
        XCTAssertEqual(events.count, 1)
        if case .page(let requested, let startSeq, let endSeq, let returned, let prepended, let attempts, let hasMore) = events[0] {
            XCTAssertEqual([requested, startSeq, endSeq, returned, prepended, attempts], [500, 440, 499, 60, 60, 1])
            XCTAssertFalse(hasMore)
        } else {
            XCTFail("expected a page diagnostic, got \(events[0])")
        }
    }
}

/// Throws once, then hands over the page.
private final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    private let handed: TranscriptPager.Page
    init(page: TranscriptPager.Page) { handed = page }

    struct Boom: Error {}
    func next() throws -> TranscriptPager.Page {
        lock.lock()
        defer { lock.unlock() }
        if failed { return handed }
        failed = true
        throw Boom()
    }
}

/// 把「在飞期间发起的那次请求」的结果带回测试任务。
private actor OutcomeBox {
    private var stored: TranscriptPager.Outcome?
    var value: TranscriptPager.Outcome { stored ?? .busy }
    func set(_ outcome: TranscriptPager.Outcome) { stored = outcome }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

private final class DiagnosticBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptPager.Diagnostic] = []
    var events: [TranscriptPager.Diagnostic] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ event: TranscriptPager.Diagnostic) { lock.lock(); storage.append(event); lock.unlock() }
}

/// 构造桩记录：自由函数，`Fetch` 是 `@Sendable`，闭包不能抓测试实例。
private func makeTestRecord(_ seq: Int) -> SessionRecord {
    let json = #"{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"content":[]}}"#
    let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    return SessionRecord(event: event)
}

private func makeTestPage(_ range: ClosedRange<Int>, hasMore: Bool) -> TranscriptPager.Page {
    TranscriptPager.Page(records: range.map(makeTestRecord), startSeq: range.lowerBound,
                         endSeq: range.upperBound, hasMore: hasMore)
}

/// 窗口裁剪：只丢行，不动"还有没有更早"，返回真丢了几行（spec 007 T021）。
@MainActor
final class TimelineWindowTests: XCTestCase {

    /// 真正会折成一行的那种记录（`user/message` 要带 content 与 source）。
    private func record(_ seq: Int) -> SessionRecord {
        let json = """
        {"type":"user/message","seq":\(seq),"time":1789276358732,
         "data":{"content":[{"type":"text","text":"m\(seq)"}],
                 "source":{"kind":"user","rpcId":"r\(seq)"},"role":"user","id":"m\(seq)"}}
        """
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    func testDroppingOldestRowsKeepsTheNewest() {
        var timeline = ChatTimeline()
        timeline.reset(with: (1...10).map(record))
        XCTAssertEqual(timeline.items.count, 10, "每个 user/message 应折成一行")
        XCTAssertEqual(timeline.dropOldestRows(4), 4)
        XCTAssertEqual(timeline.firstSeq, 5)
        XCTAssertEqual(timeline.items.count, 6)
    }

    func testDroppingMoreThanThereIsIsClamped() {
        var timeline = ChatTimeline()
        timeline.reset(with: (1...3).map(record))
        XCTAssertEqual(timeline.dropOldestRows(99), 3)
        XCTAssertEqual(timeline.items.count, 0)
        XCTAssertNil(timeline.firstSeq)
    }

    func testDroppingNothingIsANoOp() {
        var timeline = ChatTimeline()
        timeline.reset(with: (1...3).map(record))
        XCTAssertEqual(timeline.dropOldestRows(0), 0)
        XCTAssertEqual(timeline.items.count, 3)
    }
}
