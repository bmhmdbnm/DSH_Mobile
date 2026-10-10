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
        // T020：provisional 记录与提交的 assistant/message 同形，带 stream 标记。
        let provisional = first?.inserted.first?.event
        XCTAssertEqual(provisional?.data["stream"], .bool(true))
        let block = provisional?.data["message"]?["content"]?.arrayValue?.first
        XCTAssertEqual(block?["type"]?.stringValue, "text")
        XCTAssertEqual(block?["text"]?.stringValue, "hello!")

        // 下一 tick 的增量是第二次 diff。
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 3, time: nil, chunk: .textDelta(" again")))
        await gate.release()
        let second = await iterator.next()
        XCTAssertEqual(second?.updated.count, 1)
        let updated = second?.updated.first?.event.data["message"]?["content"]?.arrayValue?.first
        XCTAssertEqual(updated?["text"]?.stringValue, "hello! again")
    }

    /// T020：思考与正文分开成块；工具参数增量不进 provisional 文本。
    func testStreamReasoningAndToolDeltasStayOutOfText() async throws {
        let gate = TickGate()
        let pipeline = makePipeline { await gate.tick() }
        let diffs = await pipeline.diffs()
        var iterator = diffs.makeAsyncIterator()

        await pipeline.apply(stream: .start(attemptId: "a1", revision: 1, turn: 1, step: 1, startedAfterSeq: 10))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 0, time: nil, chunk: .reasoningDelta("想")))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 1, time: nil,
                                            chunk: .toolCallDelta(id: "c1", name: "bash", index: 0, argumentsDelta: "{\"cmd\"")))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 2, time: nil, chunk: .textDelta("答")))
        await gate.release()

        let diff = await iterator.next()
        let content = diff?.inserted.first?.event.data["message"]?["content"]?.arrayValue
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"]?.stringValue, "reasoning")
        XCTAssertEqual(content?[0]["text"]?.stringValue, "想")
        XCTAssertEqual(content?[1]["type"]?.stringValue, "text")
        XCTAssertEqual(content?[1]["text"]?.stringValue, "答")
    }

    /// T020：流被取消（end 无 committedSeq）→ provisional 行撤回；
    /// 正常提交（committedSeq 同 seq）→ 行留着等提交事件覆盖。
    func testStreamEndWithoutCommitRemovesProvisionalRow() async throws {
        let gate = TickGate()
        let pipeline = makePipeline { await gate.tick() }
        let diffs = await pipeline.diffs()
        var iterator = diffs.makeAsyncIterator()

        await pipeline.apply(stream: .start(attemptId: "a1", revision: 1, turn: 1, step: 1, startedAfterSeq: 20))
        await pipeline.apply(stream: .chunk(attemptId: "a1", revision: 1, index: 0, time: nil, chunk: .textDelta("hi")))
        await gate.release()
        _ = await iterator.next() // insert

        // 取消：无 committedSeq → 撤回 provisional 行。
        await pipeline.apply(stream: .end(attemptId: "a1", revision: 1, index: 1, committedSeq: nil))
        let removed = await iterator.next()
        XCTAssertEqual(removed?.removed, [21])
        let snapshot = await pipeline.snapshot()
        XCTAssertNil(snapshot.records.first(where: { $0.event.seq == 21 }))

        // 正常提交：committedSeq 同 seq → 行保留，等提交事件覆盖。
        await pipeline.apply(stream: .start(attemptId: "a2", revision: 1, turn: 1, step: 1, startedAfterSeq: 30))
        await pipeline.apply(stream: .chunk(attemptId: "a2", revision: 1, index: 0, time: nil, chunk: .textDelta("ok")))
        await gate.release()
        _ = await iterator.next() // insert seq 31
        await pipeline.apply(stream: .end(attemptId: "a2", revision: 1, index: 1, committedSeq: 31))
        let stillThere = await pipeline.snapshot()
        XCTAssertEqual(stillThere.records.first(where: { $0.event.seq == 31 })?
            .event.data["stream"], .bool(true))

        // 提交事件到达：同 seq 覆盖，stream 标记消失。
        let committed = SessionEvent(
            type: "assistant/message", seq: 31, time: nil,
            data: .object(["message": .object(["content": .array([
                .object(["type": .string("text"), "text": .string("ok!")]),
            ])])]),
            surfaceOp: nil)
        await pipeline.apply(event: committed)
        let committedDiff = await iterator.next()
        XCTAssertEqual(committedDiff?.updated.count, 1)
        XCTAssertNil(committedDiff?.updated.first?.event.data["stream"])
        let final = await pipeline.snapshot()
        XCTAssertEqual(final.records.first(where: { $0.event.seq == 31 })?
            .event.data["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "ok!")
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

    // MARK: - T026：磁盘水合发 diff + 锚点定向淘汰

    /// 热窗口淘汰后回看：区间集仍声称覆盖（磁盘有），读盘补回后必须发 diff，
    /// 否则订阅方永远看不到这段——US2 遗留的静默空白带（hotLimit 被迫调到
    /// 5000 的根因）。同时验证锚点淘汰：留下读者正在看的老段，丢最远端。
    func testDiskHydrationAfterEvictionEmitsDiff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
        // 预置磁盘 1...100（模拟此前会话落库）。
        try await store.applyWrites([.upsertRecords(
            scope: "mac", sessionId: "s1", records: (1...100).map { record($0) })])
        let stub = stub!
        let pipeline = SessionPipeline(
            scope: "mac", sessionId: "s1", store: store,
            fetch: { range in try await stub.fetch(range) },
            now: { 1000 }, pageSize: 50, hotLimit: 60,
            initialRanges: RangeIndex(spans: [RangeIndex.Span(1, 100)]))
        // 热窗口只持有最新 60（模拟淘汰后的稳态）。
        for seq in 41...100 { await pipeline.apply(event: record(seq).event) }
        var snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.records.map(\.event.seq), Array(41...100))

        let diffs = await pipeline.diffs()
        var iterator = diffs.makeAsyncIterator()
        // 回看到被裁段：区间命中 → 磁盘水合（零网络）→ 必须发 diff。
        let records = try await pipeline.records(in: 1...40)
        XCTAssertEqual(records.map(\.event.seq), Array(1...40))
        let diff = await iterator.next()
        XCTAssertEqual(diff?.inserted.map(\.event.seq), Array(1...40))
        // T028 裁定：锚点淘汰仍丢最远的新端 61...100，但**不进** diff.removed
        // ——热窗口是缓存，缩窗不等于数据消失，UI 裁剪由 008 宿主两层负责。
        XCTAssertEqual(diff?.removed ?? [], [])
        snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.records.map(\.event.seq), Array(1...60))
        // 区间集不受内存淘汰影响（磁盘兜底语义不变）。
        let ranges = await pipeline.ranges
        XCTAssertEqual(ranges.spans, [RangeIndex.Span(1, 100)])
        // 全程零网络。
        let requests = await stub.allRequests()
        XCTAssertTrue(requests.isEmpty)

        // 淘汰后回看被裁段（61...100）：磁盘水合仍能取回（T028 语义闭环）。
        let rehydrated = try await pipeline.records(in: 61...100)
        XCTAssertEqual(rehydrated.map(\.event.seq), Array(61...100))
        // 水合段本身不走网络（尾沿预取 101...150 是 fire-and-forget，不在此断言）。
        let hydrationRequests = await stub.requestCount(51...100)
        XCTAssertEqual(hydrationRequests, 0)
    }

    /// T028：下行事件把热窗口推超上限时，淘汰的 seq 不出现在 diff.removed。
    func testEvictionFromDownstreamApplyDoesNotEmitRemovals() async throws {
        let pipeline = makePipeline(hotLimit: 60)
        let diffs = await pipeline.diffs()
        var iterator = diffs.makeAsyncIterator()
        // 一批 100 条直接超上限：淘汰 1...40（默认丢最老）。
        await pipeline.apply(events: (1...100).map { record($0).event })
        let diff = await iterator.next()
        XCTAssertEqual(diff?.inserted.count, 100)
        XCTAssertEqual(diff?.removed ?? [], [])
        // 热窗口确实缩到上限（淘汰本身仍发生，只是不广播）。
        let snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.records.map(\.event.seq), Array(41...100))
    }

    // MARK: - T026：降级跳转的僵尸缺口

    /// >5 页降级直跳最新页后，被丢弃的中间段没有在任何在飞拉取里，
    /// 不能停在 .loading 永远转圈（US3 遗留）：置为可重试失败，不发网络；
    /// 用户点重试才真拉，缺口随后消亡。
    func testAbandonedGapTurnsRetryableAndWaitsForUserRetry() async throws {
        let pipeline = makePipeline()
        for seq in 1...50 { await pipeline.apply(event: record(seq).event) }
        for seq in 101...150 { await pipeline.apply(event: record(seq).event) }

        await pipeline.abandonGap(51...100)
        var snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.gaps.map(\.id), ["gap:51-100"])
        XCTAssertEqual(snapshot.gaps.first?.status, .failed(retryable: true))
        // 省流量语义：丢弃中间段不得自动发网络。
        var requests = await stub.allRequests()
        XCTAssertTrue(requests.isEmpty)

        // 用户点「点击重试」：清计数后真拉，缺口消亡。
        await stub.set(51...100, .page(page(51...100)))
        try await pipeline.retry(range: 51...60)
        snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.gaps.isEmpty)
        XCTAssertEqual(snapshot.records.count, 150)
        requests = await stub.allRequests()
        XCTAssertEqual(requests, [51...100])
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
