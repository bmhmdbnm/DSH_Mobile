import Foundation

/// 单会话内存流水线（spec 009 架构决定 §2/§6/§7 / tasks T008）。
///
/// 一个会话的全部运行时状态都串行在这个 actor 里：有效连续区间集（RangeIndex）、
/// 热窗口（最近 500 条，超出淘汰最老）、in-flight 页表（同页合并/取消/抢占）、
/// 落库队列（按消息去重）、流式按帧合并的缓冲。
///
/// 对外只有三件事：
/// 1. `records(in:)` ——「取不到就拉」水合：区间集二分，命中走热窗口/磁盘，
///    缺口按对齐页（50 条）经注入的 fetch 拉网络，回包合并进三处
///    （热窗口 + 区间集 + 落库队列）并产出 `Diff`。
/// 2. `apply(event:)` / `apply(stream:)` —— 下行合并。流式增量先进缓冲，
///    经 `frameTick` 节拍（测试注入立即返回，产品接 CADisplayLink）合并成
///    一次状态变更，一个 tick 内多次增量只出一个 diff（spec 剩余卡顿源①）。
/// 3. `diffs()` —— 每次状态变化产出 `Diff`（insert/update 的记录、remove 的
///    seq、由区间集派生的 gap 行列表），供 MessagePipeline 组装快照。
///
/// 失败语义（spec 可见性兜底）：拉取失败重试上限 3 次，超限的缺口标
/// `failed(retryable: true)`；只有 `hasMore=false` 或 `clamped` 才允许「到头」，
/// 网络失败永远不得静默当作到底。
public actor SessionPipeline {

    // MARK: - 对外类型

    /// 网络取页的注入面（测试用内存脚本化假回包；产品侧适配 TranscriptPageFetcher）。
    public struct FetchPage: Sendable {
        public let records: [SessionRecord]
        public let hasMore: Bool
        /// 服务端日志被裁剪：允许「到头」（spec 场景 6 与 FR-038 语义沿用）。
        public let clamped: Bool

        public init(records: [SessionRecord], hasMore: Bool, clamped: Bool = false) {
            self.records = records
            self.hasMore = hasMore
            self.clamped = clamped
        }
    }

    public typealias PageFetch = @Sendable (ClosedRange<Int>) async throws -> FetchPage

    /// 拉取优先级（沿用 InFlightPageTable：prefetch < userVisible < jump）。
    public typealias FetchPriority = InFlightPageTable<Int>.Priority

    /// 缺口行（spec「缺口行的生命周期」）：身份 `gap:<start>-<end>` 由区间集派生。
    public struct GapRow: Sendable, Equatable, Identifiable {
        public enum Status: Sendable, Equatable {
            case loading
            case failed(retryable: Bool)
            /// 已到顶（hasMore=false / clamped），渲染「没有更多」。
            case exhausted
        }

        public let start: Int
        public let end: Int
        public let status: Status

        public var id: String { "gap:\(start)-\(end)" }

        public init(start: Int, end: Int, status: Status) {
            self.start = start
            self.end = end
            self.status = status
        }
    }

    /// 一次状态变化给上层的增量（MessagePipeline 据此组装 SnapshotDiff）。
    public struct Diff: Sendable {
        public var inserted: [SessionRecord] = []
        public var updated: [SessionRecord] = []
        public var removed: [Int] = []
        /// 当前窗口内全部 gap 行（派生量，每次整体给出，生灭交给 diff 消费方比对）。
        public var gaps: [GapRow] = []

        public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && removed.isEmpty }
    }

    public enum FetchError: Error, Equatable {
        /// 该缺口已连续失败 3 次，转 retryable，不再自动拉（等用户点击重试）。
        case gapFailed
    }

    // MARK: - 状态

    public let scope: String
    public let sessionId: String
    let pageSize: Int // internal：+Paging 扩展（页对齐工具）要用
    private let hotLimit: Int
    private let store: MessageStore?
    private let fetch: PageFetch
    let frameTick: @Sendable () async -> Void
    private let now: @Sendable () -> TimeInterval

    /// 有效连续区间集：本地（热窗口 + 磁盘）确定完整的范围。
    public private(set) var ranges = RangeIndex()

    /// 热窗口：[seq: 记录] + 有序索引，超出 hotLimit 淘汰最老（只影响内存）。
    /// internal：流式半边（SessionPipeline+Streaming）要查行是否存在。
    var hotWindow: [Int: SessionRecord] = [:]
    private var hotOrder: [Int] = []

    private var inFlight = InFlightPageTable<Int>()
    /// 在途任务本体（页表只存代数；搭车者 await 同一个 Task，任务覆盖到合并完成）。
    private var inFlightTasks: [Int: Task<Void, Error>] = [:]
    private var writes = PendingWriteQueue<Int, MessageStore.RecordChange>()

    /// 每页连续失败次数；≥ maxRetries 的缺口转 retryable。
    /// internal：gap 派生（+Paging 扩展）要读。
    var failureCounts: [Int: Int] = [:]
    /// 拉空（服务端尚无新数据）的页：避免预取瀑布反复打同一页。
    private var knownEmptyPages: Set<Int> = []
    /// 已到顶：只有 hasMore=false 或 clamped 才置位（spec 可见性兜底）。
    public private(set) var topExhausted = false

    /// 落库回调：队列 drain 的批次交给 MessageStore（盘写由上层异步消费）。
    private let flushWrites: @Sendable ([MessageStore.RecordChange]) -> Void

    // 流式合并状态在 SessionPipeline+Streaming.swift（internal：同模块扩展可见，
    // 并发安全仍由本 actor 保证，沿用 MessageStore 拆文件的先例）。
    var streamBuffers: [String: StreamBuffer] = [:]
    var streamFlushScheduled = false

    // diff 广播（多订阅者：MessagePipeline 的泵 + 测试各拿一条流）。
    private var diffContinuations: [UUID: AsyncStream<Diff>.Continuation] = [:]

    static let maxRetries = 3 // internal：gap 派生（+Paging 扩展）要读

    public init(
        scope: String,
        sessionId: String,
        store: MessageStore?,
        fetch: @escaping PageFetch,
        frameTick: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        pageSize: Int = 50,
        hotLimit: Int = 500,
        initialRanges: RangeIndex = RangeIndex(),
        flushWrites: @escaping @Sendable ([MessageStore.RecordChange]) -> Void = { _ in }
    ) {
        self.scope = scope
        self.sessionId = sessionId
        self.store = store
        self.fetch = fetch
        self.frameTick = frameTick
        self.now = now
        self.pageSize = pageSize
        self.hotLimit = hotLimit
        self.ranges = initialRanges
        self.flushWrites = flushWrites
    }

    /// 采纳磁盘层持久化的区间集（冷启动预取判定，spec §6「可随会话快照持久化」）。
    /// 只增不删：持久化区间声称的是磁盘覆盖，命中段磁盘短收时仍会转网络补齐，
    /// 所以采纳是安全的（磁盘只是缓存，不是事实来源）。
    public func adoptPersistedRanges(_ persisted: RangeIndex) {
        for span in persisted.spans {
            ranges.insert(span.start...span.end)
        }
    }

    // MARK: - diff 订阅

    /// 每次状态变化的增量流（多订阅者各自独立）。
    public func diffs() -> AsyncStream<Diff> {
        let id = UUID()
        return AsyncStream { continuation in
            diffContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeDiffContinuation(id) }
            }
        }
    }

    private func removeDiffContinuation(_ id: UUID) {
        diffContinuations.removeValue(forKey: id)
    }

    func emit(_ diff: Diff) {
        guard !diff.isEmpty || !diff.gaps.isEmpty else { return }
        for continuation in diffContinuations.values {
            continuation.yield(diff)
        }
    }

    // MARK: - 读（热窗口快照）

    /// 当前热窗口内某 seq 的记录（MessagePipeline 组装索引用）。
    public func record(at seq: Int) -> SessionRecord? { hotWindow[seq] }

    /// 当前快照：热窗口全部记录（升序）+ 派生 gap 行。新订阅者的首帧数据源。
    public func snapshot() -> (records: [SessionRecord], gaps: [GapRow]) {
        (hotOrder.sorted().compactMap { hotWindow[$0] }, currentGaps())
    }

    // MARK: - 水合（取不到就拉，spec §6 三分支）

    /// 取一个闭区间：命中部分本地直给，缺口按对齐页磁盘→网络补齐。
    /// 磁盘是纯缓存：区间声称覆盖但磁盘读不出（被淘汰/未落盘）同样转网络。
    public func records(
        in range: ClosedRange<Int>,
        priority: FetchPriority = .userVisible
    ) async throws -> [SessionRecord] {
        // 跳转抢占：取消低优先级预取，用户动作插队（spec 支撑机制 1）。
        if priority == .jump { _ = inFlight.cancelAll(below: .jump) }

        // ① 区间判定三分支：算出缺口。
        var missing: [RangeIndex.Span]
        switch ranges.coverage(of: range) {
        case .full: missing = []
        case .partial(_, let spans): missing = spans
        case .none: missing = [RangeIndex.Span(range.lowerBound, range.upperBound)]
        }

        // ② 命中部分：热窗口优先，缺的读盘；盘也读不出的并入缺口转网络。
        //    磁盘水合的记录必须发 diff（T026 修复 US2 遗留：淘汰后回看，
        //    区间集仍声称覆盖、读盘合并了却不广播，订阅方永远看不到——
        //        静默空白带的根因）。
        let hydrated = await hydrateCoveredSpans(of: range, missing: &missing)
        if !hydrated.isEmpty {
            var diff = Diff(inserted: hydrated)
            diff.removed = evictIfNeeded(anchor: Self.anchor(of: range))
            diff.gaps = currentGaps()
            emit(diff)
        }

        // ③ 缺口按对齐页拉网络（含整段缺失/跳转型完全不命中）。
        if !missing.isEmpty {
            try await fetchMissing(missing, priority: priority)
        }

        // ④ 组装结果 + 预取瀑布（spec §7：距边界约 1 页提前水合下一页）。
        let result = range.compactMap { hotWindow[$0] }
        triggerPrefetch(around: range)
        return result
    }

    /// 区间集声称覆盖、但热窗口已淘汰的段：读盘补回热窗口。
    /// 返回本次水合的记录（调用方据此发 diff）；磁盘短收的连续空洞
    /// 并入 `missing`，走同一条网络补齐路径（磁盘只是缓存，崩丢由
    /// 「取用失败即拉取」兜底，区间集不回删）。
    private func hydrateCoveredSpans(
        of range: ClosedRange<Int>, missing: inout [RangeIndex.Span]
    ) async -> [SessionRecord] {
        guard let store, !ranges.isEmpty else { return [] }
        var hydrated: [SessionRecord] = []
        let coveredSpans = ranges.spans.filter {
            $0.end >= range.lowerBound && $0.start <= range.upperBound
        }
        for span in coveredSpans {
            let from = max(span.start, range.lowerBound)
            let to = min(span.end, range.upperBound)
            let absent = (from...to).filter { hotWindow[$0] == nil }.sorted()
            guard !absent.isEmpty else { continue }
            let diskRecords = (try? await store.records(
                scope: scope, sessionId: sessionId, in: from...to)) ?? []
            var found = Set<Int>()
            for record in diskRecords where record.event.seq >= from && record.event.seq <= to {
                mergeIntoHotWindow(record)
                found.insert(record.event.seq)
                hydrated.append(record)
            }
            // 磁盘短收：把连续的空洞段并入 missing。
            var runStart: Int?
            var previous = Int.min
            for seq in absent where !found.contains(seq) {
                if runStart == nil { runStart = seq }
                if seq != previous + 1, let start = runStart, start < seq {
                    missing.append(RangeIndex.Span(start, previous))
                    runStart = seq
                }
                previous = seq
            }
            if let start = runStart {
                missing.append(RangeIndex.Span(start, previous))
            }
        }
        return hydrated
    }

    /// 缺口 → 对齐页集合，逐页拉取并合并。某页失败不阻塞其它页。
    private func fetchMissing(_ missing: [RangeIndex.Span], priority: FetchPriority) async throws {
        var firstError: Error?
        for span in missing {
            for page in alignedPages(covering: span) {
                do {
                    try await fetchPage(page, priority: priority)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
    }

    /// 单页拉取：in-flight 页表同页合并/可抢占，回包按代数核销。
    private func fetchPage(_ page: ClosedRange<Int>, priority: FetchPriority) async throws {
        let key = page.lowerBound
        if failureCounts[key, default: 0] >= Self.maxRetries {
            emit(Diff(gaps: currentGaps()))
            throw FetchError.gapFailed
        }
        // 已知为空的页：预取不重复打网络；用户主动读取不受此限（点回来了就要真拉）。
        if priority == .prefetch, knownEmptyPages.contains(key) { return }

        switch inFlight.begin(key, priority: priority) {
        case .joined:
            // 同页在途：搭车等待同一个任务（任务覆盖到合并完成，见下）。
            if let task = inFlightTasks[key] { try await task.value }
            return
        case .start(let generation):
            let fetch = self.fetch
            // 任务本体包含回包合并：搭车者 await 到的一定是「合并后」。
            let task = Task<Void, Error> {
                do {
                    let result = try await fetch(page)
                    self.completeFetch(result, key: key, generation: generation, requested: page)
                } catch {
                    self.failFetch(error, key: key, generation: generation)
                    throw error
                }
            }
            inFlightTasks[key] = task
            try await task.value
        }
    }

    /// 回包核销 + 合并（代数不符 = 已被取消，丢弃）。
    private func completeFetch(
        _ result: FetchPage, key: Int, generation: Int, requested: ClosedRange<Int>
    ) {
        inFlightTasks.removeValue(forKey: key)
        guard inFlight.finish(key, generation: generation) else { return }
        failureCounts.removeValue(forKey: key)
        mergeFetchedPage(result, pageKey: key, requested: requested)
    }

    /// 失败核销：计数 + 重发 gap 状态；3 次上限由 fetchPage 入口挡。
    private func failFetch(_ error: Error, key: Int, generation: Int) {
        inFlightTasks.removeValue(forKey: key)
        _ = inFlight.finish(key, generation: generation)
        failureCounts[key] = failureCounts[key, default: 0] + 1
        emit(Diff(gaps: currentGaps())) // 失败次数变化可能改写 gap 状态
    }

    /// 回包合并：热窗口 + 区间集 + 落库队列三路，一次 diff 产出（spec §2 下行）。
    private func mergeFetchedPage(_ page: FetchPage, pageKey: Int, requested: ClosedRange<Int>) {
        var diff = Diff()
        let pageRecords = page.records.sorted { $0.event.seq < $1.event.seq }
        // 「到头」只在拉最底页（对齐起点 1）且服务端说 hasMore=false 或被裁剪时成立
        // （spec 可见性兜底：网络失败永远不得当作到底）。
        let isBottomPage = requested.lowerBound == 1
        if pageRecords.isEmpty {
            knownEmptyPages.insert(pageKey)
            if isBottomPage, page.hasMore == false || page.clamped { topExhausted = true }
        } else {
            for record in pageRecords {
                if hotWindow[record.event.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
                mergeIntoHotWindow(record)
            }
            ranges.insert(pageRecords.first!.event.seq...pageRecords.last!.event.seq)
            enqueueWrite(.upsertRecords(scope: scope, sessionId: sessionId, records: pageRecords),
                         key: pageRecords.last!.event.seq)
            knownEmptyPages.removeAll()
            if isBottomPage, page.hasMore == false || page.clamped { topExhausted = true }
            diff.removed = evictIfNeeded(anchor: Self.anchor(of: requested))
        }
        diff.gaps = currentGaps()
        emit(diff)
    }

    /// 读者点了「加载失败，点击重试」（spec 009 失败语义 / tasks T016）：
    /// 清掉该范围覆盖对齐页的失败计数，再走一次「取不到就拉」。
    /// 除此之外没有任何路径能清零计数——失败到上限的缺口不会自己偷偷重试。
    public func retry(range: ClosedRange<Int>) async throws {
        for page in alignedPages(covering: RangeIndex.Span(range.lowerBound, range.upperBound)) {
            failureCounts.removeValue(forKey: page.lowerBound)
        }
        _ = try await records(in: range, priority: .userVisible)
    }

    // MARK: - 下行合并（WSS 推送 / 流式）

    /// 服务端提交的日志事件：直接合并（流式帧走 apply(stream:)）。
    public func apply(event: SessionEvent) {
        apply(events: [event])
    }

    /// 一批日志事件（follow 快照下行）：合并成**一次** diff——逐条 apply 会让
    /// 订阅方按条数重建（009 ChatModel 接线实测要避免的写放大）。
    public func apply(events: [SessionEvent]) {
        guard !events.isEmpty else { return }
        var diff = Diff()
        var latestKey = 0
        // 提交事件落地时作废旧流式缓冲：否则已排期的 flush 会用旧的
        // provisional 文本把刚提交的正式内容盖回去（T020）。
        discardStreamBuffers(committedAt: Set(events.compactMap {
            $0.type == "assistant/message" ? $0.seq : nil
        }))
        for event in events {
            let record = SessionRecord(event: event)
            if hotWindow[event.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
            mergeIntoHotWindow(record)
            ranges.insert(event.seq)
            latestKey = max(latestKey, event.seq)
        }
        enqueueWrite(.upsertRecords(
            scope: scope, sessionId: sessionId,
            records: events.map(SessionRecord.init)), key: latestKey)
        knownEmptyPages.removeAll()
        diff.removed = evictIfNeeded()
        diff.gaps = currentGaps()
        emit(diff)
    }

    /// 流式增量在 SessionPipeline+Streaming.swift（文件按职责拆分，见该文件头注）。

    // MARK: - 上行（MessagePipeline 的 send 走这里落库排队）

    /// 乐观记录入队（pending）/ 确认替换（confirm）：不进热窗口——上行行
    /// 的身份与排序由 MessagePipeline 持有，这里只管落库队列。
    public func enqueueWrite(_ change: MessageStore.RecordChange, key: Int) {
        writes.enqueue(key, change, now: now())
        if writes.shouldFlush(now: now()) {
            flushWrites(writes.drain(now: now()).map(\.value))
        }
    }

    /// 强制落盘（测试与退后台路径用）。
    public func flushPendingWrites() {
        guard !writes.isEmpty else { return }
        flushWrites(writes.drain(now: now()).map(\.value))
    }

    // MARK: - 预取瀑布（spec §7）

    /// 窗口滑动带提前量：距热窗口/本地区间边缘约 1 页时，以 .prefetch 触发
    /// 向下一页的水合（与用户主动请求同一路径、可被 .jump 抢占）。
    private func triggerPrefetch(around range: ClosedRange<Int>) {
        guard let oldest = ranges.oldest, let newest = ranges.newest else { return }
        if !topExhausted, oldest > 1, range.lowerBound - oldest < pageSize {
            prefetch(alignedPage(containing: oldest - 1))
        }
        if newest - range.upperBound < pageSize {
            prefetch(alignedPage(containing: newest + 1))
        }
    }

    private func prefetch(_ page: ClosedRange<Int>) {
        let key = page.lowerBound
        guard !inFlight.isInFlight(key),
              inFlightTasks[key] == nil,
              failureCounts[key, default: 0] < Self.maxRetries,
              !knownEmptyPages.contains(key)
        else { return }
        switch ranges.coverage(of: page) {
        case .none, .partial:
            Task { try? await self.fetchPage(page, priority: .prefetch) }
        case .full:
            return
        }
    }

    // MARK: - 内部工具

    func mergeIntoHotWindow(_ record: SessionRecord) {
        let seq = record.event.seq
        if hotWindow[seq] == nil { hotOrder.append(seq) }
        hotWindow[seq] = record
    }

    /// 热窗口超上限淘汰（只影响内存，磁盘由落库队列负责）。
    /// 默认丢最老（尾部到达，spec「超出丢最老已读」）；给锚点（回看水合）
    /// 时丢离锚点更远的一端——回看时把正在读的段抽走会立刻触发再水合，
    /// 形成「水合→淘汰→空白」死循环（T026）。
    /// 返回被淘汰的 seq（diff 的 removed）。
    func evictIfNeeded(anchor: Int? = nil) -> [Int] {
        guard hotOrder.count > hotLimit else { return [] }
        hotOrder.sort()
        let excess = hotOrder.count - hotLimit
        let evictOldest: Bool
        if let anchor, let first = hotOrder.first, let last = hotOrder.last {
            evictOldest = anchor - first >= last - anchor
        } else {
            evictOldest = true
        }
        let evicted = evictOldest ? Array(hotOrder.prefix(excess)) : Array(hotOrder.suffix(excess))
        if evictOldest { hotOrder.removeFirst(excess) } else { hotOrder.removeLast(excess) }
        for seq in evicted { hotWindow.removeValue(forKey: seq) }
        return evicted
    }

    /// 缺口行由区间集派生（spec「缺口行的生命周期」）：窗口 = 最老…最新。
    /// 实现在 SessionPipeline+Paging.swift（主文件 500 行上限）。
}
