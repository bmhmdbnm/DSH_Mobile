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
///
/// 淘汰语义（T028 裁定）：热窗口只是缓存，超上限缩窗**不进** `diff.removed`——被淘汰的行
/// 仍由磁盘覆盖（ranges 语义不变），回看时「取不到就拉」会水合回来；UI 侧的行裁剪由 008
/// 宿主的 reclaim/dropOldestRows 两层负责，重订阅首帧（`snapshot()`）以热窗口为准是合法的。
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

    public typealias PageFetch = @Sendable (ClosedRange<Int>, FetchPriority) async throws -> FetchPage

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

    /// 取页失败（T038 起「空页但没说到头」也算失败）。
    /// `description` 就是 App 侧探针 `pager.failed` 的 reason 口径
    /// （桥的 catch 打 `String(describing: error)`）。
    public enum FetchError: Error, Equatable, CustomStringConvertible {
        /// 该缺口已连续失败 3 次，转 retryable，不再自动拉（等用户点击重试）。
        case gapFailed
        /// 不过滤的翻页拉回 0 条且服务端没说「到头」——异常，按可重试失败处理。
        case emptyPage

        public var description: String {
            switch self {
            case .gapFailed: return "gap-failed"
            case .emptyPage: return "empty-page"
            }
        }
    }

    // MARK: - 状态

    public let scope: String
    public let sessionId: String
    let pageSize: Int // internal：+Paging 扩展（页对齐工具）要用
    private let hotLimit: Int
    /// internal：+Hydration 扩展（磁盘水合）要用。
    let store: MessageStore?
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
    /// 已到顶：只有 hasMore=false 或 clamped（服务端明确到头），或本地窗口最老
    /// 序号已经到 1（`markEarliestReached`，T037）才置位。网络失败永不置位。
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
            _ = evictIfNeeded(anchor: Self.anchor(of: range))
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
    /// 实现在 SessionPipeline+Hydration.swift（主文件 500 行上限）。

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

        switch inFlight.begin(key, priority: priority) {
        case .joined:
            // 同页在途：搭车等待同一个任务（任务覆盖到合并完成，见下）。
            if let task = inFlightTasks[key] { try await task.value }
            return
        case .start(let generation):
            let fetch = self.fetch
            // 任务本体包含回包合并：搭车者 await 到的一定是「合并后」。
            let task = Task<Void, Error> {
                let result: FetchPage
                do { result = try await fetch(page, priority) }
                catch {
                    self.failFetch(error, key: key, generation: generation)
                    throw error
                }
                // T038（spec 追加修订 2「空页即异常」）：不过滤的翻页拉回 0 条且
                // 服务端没说到头 = 可重试失败，走与网络失败**同一条**计数路径
                // （failFetch）——3 次后缺口转 failed(retryable)，探针口径
                // reason=empty-page（App 侧 catch 打 String(describing: error)）。
                // 原来这里记进 knownEmptyPages 静默跳过，预取假装没事。
                //
                // 关键分界：带回填过滤（roles）的空页是**正常形态**——整页被过滤掉
                // 而已，由 T039 的 scanBoundary 处理，不走本失败路径。过滤分页用的是
                // `UserInputBackfiller` 自己的 fetch（不经 SessionPipeline），而本管道
                // 的取页闭包不带 roles（产品侧 MessageLayer 用 through: nil、无 roles
                // 的 _link/sessionWindow），所以「0 条即异常」在本路径上成立。
                guard !result.records.isEmpty || Self.reachedEnd(result, requested: page) else {
                    self.failFetch(FetchError.emptyPage, key: key, generation: generation)
                    throw FetchError.emptyPage
                }
                self.completeFetch(result, key: key, generation: generation, requested: page)
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
        mergeFetchedPage(result, requested: requested)
    }

    /// 失败核销：计数 + 重发 gap 状态；3 次上限由 fetchPage 入口挡。
    /// 网络失败与 T038 的空页失败共用这一条路径（计数口径一致）。
    private func failFetch(_ error: Error, key: Int, generation: Int) {
        inFlightTasks.removeValue(forKey: key)
        _ = inFlight.finish(key, generation: generation)
        failureCounts[key] = failureCounts[key, default: 0] + 1
        emit(Diff(gaps: currentGaps())) // 失败次数变化可能改写 gap 状态
    }

    /// 回包合并：热窗口 + 区间集 + 落库队列三路，一次 diff 产出（spec §2 下行）。
    private func mergeFetchedPage(_ page: FetchPage, requested: ClosedRange<Int>) {
        var diff = Diff()
        let pageRecords = page.records.sorted { $0.event.seq < $1.event.seq }
        if pageRecords.isEmpty {
            // T038：非「明确到头」的空回包在 fetchPage 上游已按失败抛掉，能落到
            // 这里的空回包就是正常终态（最底页 + hasMore=false / clamped）。
            if Self.reachedEnd(page, requested: requested) { topExhausted = true }
        } else {
            for record in pageRecords {
                if hotWindow[record.event.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
                mergeIntoHotWindow(record)
            }
            ranges.insert(pageRecords.first!.event.seq...pageRecords.last!.event.seq)
            enqueueWrite(.upsertRecords(scope: scope, sessionId: sessionId, records: pageRecords),
                         key: pageRecords.last!.event.seq)
            if Self.reachedEnd(page, requested: requested) { topExhausted = true }
            _ = evictIfNeeded(anchor: Self.anchor(of: requested))
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
        _ = evictIfNeeded()
        diff.gaps = currentGaps()
        emit(diff)
    }

    /// 本地窗口最老序号已经到 1（T037 / spec 追加修订 1、3）：seq 从 1 编号，
    /// 没有更早的记录可拉，直接置「已到最早」——语义与 `hasMore=false` 的到头
    /// 等同（预取停手、gap 行渲染「没有更多」），只是判定来源是本地事实而不是
    /// 服务端回包。桥在 `loadOlder` 看到窗口最老 ≤ 1 时调这里，替代原来的静默
    /// return；只置位不撤销（记录只往新处增长）。
    public func markEarliestReached() {
        guard !topExhausted else { return }
        topExhausted = true
        emit(Diff(gaps: currentGaps()))
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
        // 预取是背景动作：该页只要失败过一次（网络错、或 T038 的空页）就不再
        // 自动重打，免得瀑布反复撞同一页。用户主动读取不受此限（fetchPage 入口
        // 只挡 maxRetries），点重试会清零计数，恢复正常后预取也回来。
        guard !inFlight.isInFlight(key),
              inFlightTasks[key] == nil,
              failureCounts[key, default: 0] == 0
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
    /// 返回被淘汰的 seq：仅内部记账/测试断言用——T028 裁定淘汰**不进**
    /// `diff.removed`（热窗口是缓存不是事实，见头注「淘汰语义」）。
    @discardableResult
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
