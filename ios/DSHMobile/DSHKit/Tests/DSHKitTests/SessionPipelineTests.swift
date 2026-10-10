@testable import DSHKit
import XCTest

/// SessionPipeline（spec 009 / tasks T008）：
/// 区间判定三分支、gap 派生与生灭、热窗口淘汰、流式按帧合并、
/// 失败 3 次转 retryable、预取瀑布触发时机、in-flight 同页合并。
final class SessionPipelineTests: XCTestCase {

    // MARK: - 假件

    /// 内存脚本化取页器：按对齐页起点登记回包；未登记的页默认拉空（hasMore=true）。
    private actor FetchStub {
        enum Entry {
            case page(SessionPipeline.FetchPage)
            case error(String)
        }

        private var script: [Int: Entry] = [:]
        private(set) var requests: [ClosedRange<Int>] = []

        func set(_ range: ClosedRange<Int>, _ entry: Entry) { script[range.lowerBound] = entry }
        func requestCount(_ range: ClosedRange<Int>) -> Int { requests.filter { $0 == range }.count }
        func allRequests() -> [ClosedRange<Int>] { requests }

        func fetch(_ range: ClosedRange<Int>) throws -> SessionPipeline.FetchPage {
            requests.append(range)
            switch script[range.lowerBound] {
            case .page(let page): return page
            case .error(let reason): throw TestError.message(reason)
            case nil: return SessionPipeline.FetchPage(records: [], hasMore: true)
            }
        }
    }

    private enum TestError: Error, Equatable { case message(String) }

    /// 手动闸门 frameTick：挂起直到 release()；credit 机制允许 release 先于 wait。
    private actor TickGate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var credits = 0

        func tick() async {
            if credits > 0 {
                credits -= 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty {
                credits += 1
            } else {
                let all = waiting
                waiting.removeAll()
                for continuation in all { continuation.resume() }
            }
        }
    }

    private var stub: FetchStub!

    override func setUp() {
        stub = FetchStub()
    }

    private func record(_ seq: Int, text: String = "hello") -> SessionRecord {
        let json = #"{"type":"assistant/message","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)"}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    private func page(_ range: ClosedRange<Int>, hasMore: Bool = true) -> SessionPipeline.FetchPage {
        SessionPipeline.FetchPage(records: range.map { record($0) }, hasMore: hasMore)
    }

    private func makePipeline(
        hotLimit: Int = 500,
        tick: @escaping @Sendable () async -> Void = {}
    ) -> SessionPipeline {
        let stub = stub!
        return SessionPipeline(
            scope: "mac", sessionId: "s1", store: nil,
            fetch: { range in try await stub.fetch(range) },
            frameTick: tick, now: { 1000 }, pageSize: 50, hotLimit: hotLimit)
    }

    /// 等异步沉淀的轻量工具（prefetch/diff 广播是 fire-and-forget）。
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - 区间判定三分支

    func testFullCoverageServesLocallyWithoutNetwork() async throws {
        let pipeline = makePipeline()
        await stub.set(1...50, .page(page(1...50, hasMore: false)))
        _ = try await pipeline.records(in: 1...50)
        await settle() // 首读的上沿预取（51...100 拉空）落定后再取基线
        let before = await stub.allRequests()

        let records = try await pipeline.records(in: 10...20)
        await settle()
        XCTAssertEqual(records.map(\.event.seq), Array(10...20))
        // 完全命中：零网络（51...100 已标记拉空，不会再打）。
        let after = await stub.allRequests()
        XCTAssertEqual(before, after)
        let exhausted = await pipeline.topExhausted
        XCTAssertTrue(exhausted) // hasMore=false → 到头
    }

    func testPartialCoverageFetchesOnlyMissingPages() async throws {
        let pipeline = makePipeline()
        await stub.set(1...50, .page(page(1...50, hasMore: false)))
        await stub.set(51...100, .page(page(51...100)))
        _ = try await pipeline.records(in: 1...50)

        let records = try await pipeline.records(in: 25...74)
        XCTAssertEqual(records.map(\.event.seq), Array(25...74))
        // 缺口按对齐页拉：只发 51...100，不重拉已覆盖的 1...50。
        let firstPageRequests = await stub.requestCount(1...50)
        XCTAssertEqual(firstPageRequests, 1)
        let gapRequests = await stub.requestCount(51...100)
        XCTAssertEqual(gapRequests, 1)
    }

    func testNoCoverageFetchesAlignedPagesAroundTarget() async throws {
        let pipeline = makePipeline()
        await stub.set(51...100, .page(page(51...100)))
        // 跳转型完全不命中：只拉目标所在的对齐页。
        let records = try await pipeline.records(in: 60...70, priority: .jump)
        XCTAssertEqual(records.map(\.event.seq), Array(60...70))
        let pageRequests = await stub.requestCount(51...100)
        XCTAssertEqual(pageRequests, 1)
        // 水合动作本身只发目标对齐页（预取瀑布是另一路径，不在此断言）。
    }

    // MARK: - gap 派生与生灭

    func testGapRowDerivedFromRangeIndexAndDiesWhenFilled() async throws {
        let pipeline = makePipeline()
        // 用下行事件预置两段窗口（不经 records()，避免预取提前填洞造成竞态）。
        for seq in 1...50 { await pipeline.apply(event: record(seq).event) }
        for seq in 101...150 { await pipeline.apply(event: record(seq).event) }

        var snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.gaps.map(\.id), ["gap:51-100"])
        XCTAssertEqual(snapshot.gaps.first?.status, .loading)

        await stub.set(51...100, .page(page(51...100)))
        _ = try await pipeline.records(in: 51...75)
        snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.gaps.isEmpty)
        XCTAssertEqual(snapshot.records.count, 150)
    }

    // MARK: - 热窗口淘汰

    func testHotWindowEvictsOldestBeyondLimit() async throws {
        let pipeline = makePipeline(hotLimit: 10)
        for seq in 1...25 {
            await pipeline.apply(event: record(seq).event)
        }
        let snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.records.map(\.event.seq), Array(16...25))
        // 区间集不受内存淘汰影响（磁盘兜底）。
        let ranges = await pipeline.ranges
        XCTAssertEqual(ranges.spans, [RangeIndex.Span(1, 25)])
    }

    // MARK: - 流式按帧合并

    func testStreamDeltasCoalesceIntoOneDiffPerTick() async throws {
        let gate = TickGate()
        let pipeline = makePipeline { await gate.tick() }
        let diffs = await pipeline.diffs()
        var iterator = diffs.makeAsyncIterator()

        await pipeline.apply(stream: .start(attemptId: "a1", revision: 1, turn: 1, step: 1, startedAfterSeq: 40))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 0, time: nil, chunk: .textDelta("he")))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 1, time: nil, chunk: .textDelta("llo")))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 2, time: nil, chunk: .textDelta("!")))
        await gate.release()

        // 同一 tick 内三次增量 → 恰好一次 diff，文本已合并。
        let first = await iterator.next()
        XCTAssertEqual(first?.inserted.count, 1)
        XCTAssertEqual(first?.inserted.first?.event.seq, 41)
        XCTAssertEqual(first?.inserted.first?.event.data["text"]?.stringValue, "hello!")

        // 下一 tick 的增量是第二次 diff。
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 3, time: nil, chunk: .textDelta(" again")))
        await gate.release()
        let second = await iterator.next()
        XCTAssertEqual(second?.updated.count, 1)
        XCTAssertEqual(second?.updated.first?.event.data["text"]?.stringValue, "hello! again")
    }

    // MARK: - 失败语义

    func testFetchFailsThreeTimesThenTurnsRetryable() async throws {
        let pipeline = makePipeline()
        // 下行事件预置两段窗口，缺口 51...100 的页脚本成永远失败。
        for seq in 1...50 { await pipeline.apply(event: record(seq).event) }
        for seq in 101...150 { await pipeline.apply(event: record(seq).event) }
        await stub.set(51...100, .error("boom"))

        for _ in 0..<3 {
            _ = try? await pipeline.records(in: 55...60)
        }
        let snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.gaps.map(\.id), ["gap:51-100"])
        XCTAssertEqual(snapshot.gaps.first?.status, .failed(retryable: true))
        let exhausted = await pipeline.topExhausted
        XCTAssertFalse(exhausted) // 网络失败永远不得当作到底

        // 第 4 次不再打网络。
        _ = try? await pipeline.records(in: 55...60)
        let requests = await stub.requestCount(51...100)
        XCTAssertEqual(requests, 3)
    }

    // MARK: - 预取瀑布

    func testPrefetchTriggersWithinOnePageOfCoverageEdge() async throws {
        let pipeline = makePipeline()
        await stub.set(51...100, .page(page(51...100)))
        _ = try await pipeline.records(in: 51...100)

        // 距上边界 < 1 页（100-105... 取到 95 即距尾 5）→ 预取下一页 101...150。
        _ = try await pipeline.records(in: 90...95)
        await settle()
        let upperPrefetch = await stub.requestCount(101...150)
        XCTAssertEqual(upperPrefetch, 1)
    }

    func testPrefetchTriggersNearLowerEdgeOnlyWithinOnePage() async throws {
        let pipeline = makePipeline()
        // 用下行事件预置窗口 101...200（不经 records()，避免贴边读取先触发预取）。
        for seq in 101...200 {
            await pipeline.apply(event: record(seq).event)
        }

        // 距下边界 ≥ 1 页（155-101=54）：不触发上一页预取。
        _ = try await pipeline.records(in: 155...160)
        await settle()
        var lowerPrefetch = await stub.requestCount(51...100)
        XCTAssertEqual(lowerPrefetch, 0)

        // 距下边界 < 1 页（120-101=19）：预取上一页 51...100。
        await stub.set(51...100, .page(page(51...100)))
        _ = try await pipeline.records(in: 120...130)
        await settle()
        lowerPrefetch = await stub.requestCount(51...100)
        XCTAssertEqual(lowerPrefetch, 1)
    }

    func testNoPrefetchWhenFarFromEdges() async throws {
        let pipeline = makePipeline()
        await stub.set(1...50, .page(page(1...50, hasMore: false)))
        await stub.set(51...100, .page(page(51...100)))
        await stub.set(101...150, .page(page(101...150)))
        await stub.set(151...200, .page(page(151...200)))
        _ = try await pipeline.records(in: 1...150)
        await settle() // 上沿预取 151...200 落定后取基线
        let baseline = await stub.allRequests()

        // 居中读取：离两边都 ≥ 1 页，不触发预取。
        _ = try await pipeline.records(in: 70...80)
        await settle()
        let after = await stub.allRequests()
        XCTAssertEqual(after, baseline)
    }

    // MARK: - in-flight 同页合并

    func testConcurrentRequestsForSamePageMergeIntoOneFetch() async throws {
        let pipeline = makePipeline()
        await stub.set(51...100, .page(page(51...100)))
        async let first = pipeline.records(in: 55...60)
        async let second = pipeline.records(in: 62...66)
        let (older, newer) = try await (first, second)
        XCTAssertEqual(older.map(\.event.seq), Array(55...60))
        XCTAssertEqual(newer.map(\.event.seq), Array(62...66))
        let requests = await stub.requestCount(51...100)
        XCTAssertEqual(requests, 1) // 同页合并，只发一次网络请求
    }
}
