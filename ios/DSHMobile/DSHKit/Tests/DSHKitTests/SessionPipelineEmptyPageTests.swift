@testable import DSHKit
import XCTest

/// `SessionPipeline` 的空回包方向语义（T038 起「空页即异常」+ adeb3aa 分方向）
/// 与「点重试只按缺口重拉」（T041 核对）的单测。
///
/// 单独一个文件而不是塞回 `SessionPipelineTests.swift`：那个文件已经超
/// 500 行上限（宪法第 VII 条），新语义自成一组，放这里两边都不再长。
final class SessionPipelineEmptyPageTests: XCTestCase {

    // MARK: - 假件（与 SessionPipelineTests 同款最小集：脚本化取页 + 记录构造）

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

    private func makePipeline() -> SessionPipeline {
        let stub = stub!
        return SessionPipeline(
            scope: "mac", sessionId: "s1", store: nil,
            fetch: { range, _ in try await stub.fetch(range) },
            frameTick: {}, now: { 1000 }, pageSize: 50, hotLimit: 500)
    }

    /// 等异步沉淀的轻量工具（预取/diff 广播是 fire-and-forget）。
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - adeb3aa：空页语义分方向（更新方向探空是正常形态）

    /// 方向判据只有一份：管道判「空回包算不算失败」用它，App 侧的空回包注入
    /// （`-DSHProbeEmptyPage` 只许打在更早方向）也用它。
    func testNewerDirectionProbeComparesAgainstHotWindowNewest() {
        // 还没有热窗口（冷启动首拉就是最新页）：不是"探"，不算更新方向。
        XCTAssertFalse(SessionPipeline.isNewerDirectionProbe(pageLowerBound: 151, hotNewest: nil))
        XCTAssertTrue(SessionPipeline.isNewerDirectionProbe(pageLowerBound: 151, hotNewest: 150))
        // 与窗口尾部同页/更早都算更早方向——只有**整体在最新 seq 之上**才是探空。
        XCTAssertFalse(SessionPipeline.isNewerDirectionProbe(pageLowerBound: 150, hotNewest: 150))
        XCTAssertFalse(SessionPipeline.isNewerDirectionProbe(pageLowerBound: 101, hotNewest: 150))
    }

    /// 往更新方向探空**不是失败**：不计失败计数、不置 topExhausted，且探空一次
    /// 之后不再重探同一页（新记录到达才复位）。这条语义（adeb3aa）此前没有单测。
    func testEmptyPageInNewerDirectionIsNormalAndNotReprobed() async throws {
        let pipeline = makePipeline()
        // 窗口 51...150：读 130...150 时下沿离得远（不会触发更早方向的预取），
        // 只会在上沿探 151...200（未登记 = 空回包 hasMore=true）。
        for seq in 51...150 { await pipeline.apply(event: record(seq).event) }

        // 请求区间整体在热窗口最新（150）之上 = 更新方向探空。
        _ = try await pipeline.records(in: 130...150)
        await settle()
        var failures = await pipeline.failureCounts
        XCTAssertTrue(failures.isEmpty)
        var exhausted = await pipeline.topExhausted
        XCTAssertFalse(exhausted)
        var probes = await stub.requestCount(151...200)
        XCTAssertEqual(probes, 1)

        // 同一边界再读一次：探空过就不再重探（live 更新走 follow 流）。
        _ = try await pipeline.records(in: 130...150)
        await settle()
        probes = await stub.requestCount(151...200)
        XCTAssertEqual(probes, 1)

        // 新记录到达即复位：窗口尾部抬高之后再触边仍会探。
        await pipeline.apply(event: record(151).event)
        _ = try await pipeline.records(in: 130...150)
        await settle()
        probes = await stub.requestCount(151...200)
        XCTAssertEqual(probes, 2)
        let snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.records.map(\.event.seq).contains(151))
    }

    // MARK: - T041：点重试只按缺口重拉

    /// 读者点「加载失败，点击重试」时只许重拉**缺口覆盖的那一页**：
    /// `retry(range:)` 清掉该页的失败计数后走 `records(in:)`，后者按区间集算缺口，
    /// 已经成功覆盖的相邻页零网络。2026-10-11 用例 76 的 run 20261011-203147 里
    /// 「同一页取两次」是两次冷启动（两个 App 进程各自算区间集）造成的，不是重试；
    /// 这条测试把「重试不重取已成功页」钉在单测里，免得再靠读日志判断。
    func testRetryGapDoesNotRefetchCoveredNeighbourPages() async throws {
        let pipeline = makePipeline()
        await stub.set(1...50, .page(page(1...50, hasMore: false)))
        await stub.set(51...100, .error("boom"))
        await stub.set(101...150, .page(page(101...150)))
        _ = try await pipeline.records(in: 1...50)
        _ = try? await pipeline.records(in: 51...60)   // 失败：51...100 成缺口
        _ = try await pipeline.records(in: 101...150)
        await settle()
        let before = await stub.allRequests()
        XCTAssertEqual(before.filter { $0 == 1...50 }.count, 1)
        XCTAssertEqual(before.filter { $0 == 101...150 }.count, 1)

        await stub.set(51...100, .page(page(51...100)))
        try await pipeline.retry(range: 51...60)
        await settle()

        let after = await stub.allRequests()
        XCTAssertEqual(after.filter { $0 == 51...100 }.count, 2)   // 失败一次 + 重试一次
        XCTAssertEqual(after.filter { $0 == 1...50 }.count, 1)     // 已成功页不重取
        XCTAssertEqual(after.filter { $0 == 101...150 }.count, 1)
        let snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.gaps.isEmpty)
    }
}
