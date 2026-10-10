@testable import DSHKit
import XCTest

/// tasks T014/T016 的套件内验证：
/// - `SessionPipeline.retry`：失败 3 次转 retryable 之后，只有「点击重试」
///   能清计数并真的再打网络；失败永远不得置 topExhausted。
/// - `ChatTimeline.setGaps / restoreTransient`：缺口行整体替换、身份稳定、
///   数据行不动；重建时在飞状态（流式气泡、乐观回声）被接回。
final class PipelineRetryAndGapTests: XCTestCase {

    private actor FetchStub {
        private var failures = 0
        private(set) var requests = 0

        func fail(_ times: Int) { failures = times }
        func reset() { failures = 0; requests = 0 }

        func fetch(_ range: ClosedRange<Int>) throws -> SessionPipeline.FetchPage {
            requests += 1
            if failures > 0 { failures -= 1; throw TestError.boom }
            return SessionPipeline.FetchPage(
                records: range.map { StubRecords.record($0) }, hasMore: false)
        }
    }

    private enum TestError: Error { case boom }

    private enum StubRecords {
        static func record(_ seq: Int) -> SessionRecord {
            let json = #"{"type":"assistant/message","seq":\#(seq),"time":1789276358732,"data":{"text":"t"}}"#
            let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
            return SessionRecord(event: event)
        }
    }

    private func makePipeline(_ stub: FetchStub) -> SessionPipeline {
        SessionPipeline(
            scope: "mac", sessionId: "s1", store: nil,
            fetch: { range in try await stub.fetch(range) },
            pageSize: 50, hotLimit: 500)
    }

    // MARK: - T016：重试语义

    func testRetryClearsFailureCountAndRefetches() async throws {
        let stub = FetchStub()
        let pipeline = makePipeline(stub)
        // 两段窗口夹出缺口 51...100，脚本成永远失败。
        for seq in 1...50 { await pipeline.apply(event: StubRecords.record(seq).event) }
        for seq in 101...150 { await pipeline.apply(event: StubRecords.record(seq).event) }
        await stub.fail(Int.max)

        for _ in 0..<3 { _ = try? await pipeline.records(in: 55...60) }
        var snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.gaps.first?.status, .failed(retryable: true))
        let failedRequests = await stub.requests
        XCTAssertEqual(failedRequests, 3) // 上限之后不再打网络

        // 「点击重试」：清计数，重拉成功，缺口消失。
        await stub.reset()
        try await pipeline.retry(range: 51...100)
        snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.gaps.isEmpty)
        XCTAssertEqual(snapshot.records.count, 150)
        let requests = await stub.requests
        XCTAssertEqual(requests, 1)
    }

    func testFailedGapNeverMarksExhausted() async throws {
        let stub = FetchStub()
        let pipeline = makePipeline(stub)
        for seq in 1...50 { await pipeline.apply(event: StubRecords.record(seq).event) }
        for seq in 101...150 { await pipeline.apply(event: StubRecords.record(seq).event) }
        await stub.fail(Int.max)

        for _ in 0..<4 { _ = try? await pipeline.records(in: 55...60) }
        let exhausted = await pipeline.topExhausted
        XCTAssertFalse(exhausted) // 网络失败永远不得当作「已到最早」
    }

    func testRetryWithoutFailureIsJustARefetch() async throws {
        let stub = FetchStub()
        let pipeline = makePipeline(stub)
        for seq in 1...50 { await pipeline.apply(event: StubRecords.record(seq).event) }
        for seq in 101...150 { await pipeline.apply(event: StubRecords.record(seq).event) }
        try await pipeline.retry(range: 51...100)
        let snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.gaps.isEmpty)
    }

    // MARK: - T014：缺口行折叠语义

    func testSetGapsReplacesInPlaceAndKeepsDataRows() {
        var timeline = ChatTimeline()
        _ = timeline.reset(with: (1...3).map(StubRecords.record))
        let before = timeline.items.map(\.id)

        timeline.setGaps([ChatTimeline.gapItem(start: 10, end: 20, status: .loading)])
        XCTAssertEqual(timeline.items.map(\.id), before + ["gap:10-20"])
        XCTAssertEqual(timeline.items.last?.seq, 10)

        // 状态变化：身份不变（spinner → 点击重试是同一行）。
        timeline.setGaps([ChatTimeline.gapItem(start: 10, end: 20, status: .failed(retryable: true))])
        XCTAssertEqual(timeline.items.map(\.id), before + ["gap:10-20"])
        guard case .gap(_, _, let status) = timeline.items.last?.kind else {
            return XCTFail("缺口行被弄丢了")
        }
        XCTAssertEqual(status, .failed(retryable: true))

        // 补齐：缺口行消失，数据行一行不少。
        timeline.setGaps([])
        XCTAssertEqual(timeline.items.map(\.id), before)
    }

    func testGapSortsByRangePosition() {
        var timeline = ChatTimeline()
        // 数据行 seq 1..3（折叠成若干行），缺口 10...20 排在后面，0 排在最前。
        _ = timeline.reset(with: (1...3).map(StubRecords.record))
        timeline.setGaps([
            ChatTimeline.gapItem(start: 10, end: 20, status: .loading),
            ChatTimeline.gapItem(start: 0, end: 0, status: .exhausted),
        ])
        XCTAssertEqual(timeline.items.first?.id, "gap:0-0")
        XCTAssertEqual(timeline.items.last?.id, "gap:10-20")
    }

    func testRestoreTransientKeepsEchoAndStreaming() {
        var timeline = ChatTimeline()
        _ = timeline.reset(with: [StubRecords.record(1)])
        _ = timeline.echoUserPrompt(requestId: "r1", text: "hi")
        _ = timeline.apply(AssistantStreamFrame.start(
            attemptId: "a1", revision: 1, turn: 1, step: 1, startedAfterSeq: 1))
        let streaming = timeline.streaming
        let echoes = ChatModelEchoes.pending(in: timeline.items)

        var rebuilt = ChatTimeline()
        _ = rebuilt.reset(with: [StubRecords.record(1), StubRecords.record(2)])
        rebuilt.restoreTransient(streaming: streaming, echoes: echoes)

        XCTAssertNotNil(rebuilt.streaming)
        XCTAssertTrue(rebuilt.items.contains(where: { $0.id == "user-r1" }))
        XCTAssertEqual(rebuilt.items.filter { $0.id == "user-r1" }.count, 1)
    }

    /// 与 App 侧 ChatModel.pendingEchoes 同口径（DSHKit 内自测，避免依赖 App target）。
    private enum ChatModelEchoes {
        static func pending(in items: [TimelineItem]) -> [TimelineItem] {
            items.filter { item in
                guard case .userMessage(_, _, _, let isPending, _) = item.kind else { return false }
                return isPending
            }
        }
    }
}
