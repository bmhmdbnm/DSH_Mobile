import DSHKit
import Foundation

/// 009 渲染数据源接线（tasks T013/T016，spec 009「UI 刷新推导」场景 4/5/6）。
///
/// `ChatModel` 已超 500 行，所以「订阅 MessagePipeline 快照 → 折叠 → 落回时间线」
/// 整段在新文件里：桥（`ChatPipelineBridge`）持有订阅任务与重建状态，
/// `ChatModel` 主文件只留存储属性与几个写私有成员的落点方法。
///
/// 纪律：
/// - 数据行经现有 `ChatTimeline` 折叠成 `TimelineItem`（008 的行身份与折叠语义不变）；
///   `.gap` 行按同一身份（`gap:<start>-<end>`）映射成缺口占位行。
/// - 折叠是重活，离开主线程做；代数戳保证只有最新一次重建落地（慢折叠不得覆盖新快照）。
/// - 用户动作转发：向上翻页 → `records(in:, .userVisible)`；跳转 → `.jump`；
///   失败缺口点击 → `SessionPipeline.retry`（3 次重试上限由管道接管，UI 只渲染状态）。
extension ChatModel {

    /// 渲染数据源是否已切到 MessagePipeline（决定宿主走原子 reconcile 与缺口行渲染）。
    var pipelineActive: Bool { pipelineBridge != nil }

    /// 打开会话时启动订阅（open() 在 `warmMessageLayer` 之后调用：地址簿已登记、
    /// 最新页已按 .jump 插队水合，首帧快照通常直接有数据）。
    func startPipelineSubscription(for summary: SessionSummary) {
        pipelineBridge?.stop()
        pipelineBridge = nil
        guard let pipeline = messageLayer?.pipeline, let scope = sessionScope else { return }
        let ref = MessagePipeline.SessionRef(scope: scope, sessionId: summary.sessionId)
        pipelineBridge = ChatPipelineBridge(model: self, pipeline: pipeline, ref: ref)
    }

    /// 关会话/换连接时停掉订阅（订阅的 onTermination 会自行从管道注销）。
    func stopPipelineSubscription() {
        pipelineBridge?.stop()
        pipelineBridge = nil
    }

    /// 缺口行「加载失败，点击重试」（T016：清计数后重拉，3 次上限仍由管道把守）。
    func retryGap(start: Int, end: Int) async {
        await pipelineBridge?.retryGap(start: start, end: end)
    }
}

/// 每会话一份的 009 接线状态：快照里的有序记录、缺口行、折叠代数。
@MainActor
final class ChatPipelineBridge {

    private weak var model: ChatModel?
    private let pipeline: MessagePipeline
    private let ref: MessagePipeline.SessionRef
    /// 会话级管道（拿一次存下来：取页/重试/读 topExhausted 都走它）。
    private var session: SessionPipeline?

    /// 快照数据行的唯一事实来源（seq → 记录；与 MessagePipeline 的广播保持一致）。
    private var records: [Int: SessionRecord] = [:]
    /// 行 id → seq（.remove 按行 id 核销用）。
    private var rowSeqs: [String: Int] = [:]
    /// 当前缺口行（派生量的最新一份）。
    private var gaps: [SessionPipeline.GapRow] = []
    /// 管道判定的「已到最早」（hasMore=false / clamped；网络失败永不置位）。
    private var topExhausted = false

    private var subscription: Task<Void, Never>?
    /// 折叠代数：慢折叠回来时若已过期就丢弃（新快照优先）。
    private var foldGeneration = 0
    /// 「向上翻页」进行中（顶部缺口行 spinner 由它驱动，镜像进 model.isLoadingOlder）。
    private var isLoadingOlder = false
    /// 最近一次取页失败原因（顶部缺口行据此转「点击重试」）。
    private var olderFailure: String?
    /// 失败后的一次自动补试（沿用 007 FR-004 语义：只补一次，不循环）。
    private var didAutoRetry = false

    /// 一次「向上翻页」拉多少条（与管道页大小一致）。
    private static let pageSize = 50

    init(model: ChatModel, pipeline: MessagePipeline, ref: MessagePipeline.SessionRef) {
        self.model = model
        self.pipeline = pipeline
        self.ref = ref
        subscribe()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: - 订阅

    private func subscribe() {
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let session = await self.pipeline.pipeline(for: self.ref)
            self.session = session
            let stream = await self.pipeline.snapshots(for: self.ref)
            for await diff in stream {
                if Task.isCancelled { return }
                self.apply(diff)
            }
        }
    }

    /// 一次 SnapshotDiff（可能同时含头部插入 + gap 生灭 + 尾部更新）落到
    /// 桥状态，然后触发一次重建——宿主那边由 reconcile 作为一次原子更新提交。
    private func apply(_ diff: MessagePipeline.SnapshotDiff) {
        var messagesChanged = false
        var gapsChanged = false
        var hasRemove = false
        /// T020 流式快进路候选：diff 里只有 provisional 行的 update 时，
        /// 只改那一行的文本，不整树重折（每 token 一批 diff 时整树重折是主开销）。
        var streamUpdates: [(seq: Int, text: String, reasoning: String)] = []
        var onlyStreamingUpdates = true
        // 尾部到达计数（T018 未读数）：只数"比现有最大 seq 还新"的插入——
        // 向上翻页的 prepend 与首帧快照都不算（后者由 maxSeqBefore == nil 排除）。
        let maxSeqBefore = records.keys.max()
        var tailArrivals = 0
        for change in diff.changes {
            switch change {
            case .remove(let ids):
                hasRemove = true
                onlyStreamingUpdates = false
                for id in ids {
                    if let seq = rowSeqs.removeValue(forKey: id) {
                        records.removeValue(forKey: seq)
                        messagesChanged = true
                    } else if gaps.contains(where: { $0.id == id }) {
                        gaps.removeAll { $0.id == id }
                        gapsChanged = true
                    }
                }
            case .insert(let rows), .update(let rows):
                if case .insert = change { onlyStreamingUpdates = false }
                for row in rows {
                    switch row {
                    case .message(let message):
                        if let before = maxSeqBefore, message.seq > before { tailArrivals += 1 }
                        records[message.seq] = message.record
                        rowSeqs[message.id.uuidString] = message.seq
                        messagesChanged = true
                        if onlyStreamingUpdates,
                           let content = Self.streamingContent(of: message.record) {
                            streamUpdates.append((message.seq, content.text, content.reasoning))
                        }
                    case .gap(let gap):
                        onlyStreamingUpdates = false
                        if let index = gaps.firstIndex(where: { $0.id == gap.id }) {
                            gaps[index] = gap
                        } else {
                            gaps.append(gap)
                        }
                        gapsChanged = true
                    }
                }
            }
        }
        if tailArrivals > 0 { model?.noteTailArrivals(tailArrivals) }
        // 快进路：全部增量都是"流式行文本变长"且缺口/删除都没动 → 单行更新。
        // 提交由 reconcile 走 008 统一锚一次修正（T021），不单独触发布局。
        if onlyStreamingUpdates, !hasRemove, !gapsChanged, !streamUpdates.isEmpty,
           let model, streamUpdates.allSatisfy({
               model.applyStreamingRow(seq: $0.seq, text: $0.text, reasoning: $0.reasoning)
           }) {
            return
        }
        refold(messagesChanged: messagesChanged, gapsChanged: gapsChanged)
    }

    /// provisional 记录的流式内容（text/reasoning）；非流式记录返回 nil。
    /// 判定只看 `stream` 标记——管道在 SessionPipeline+Streaming 里打的。
    private static func streamingContent(of record: SessionRecord) -> (text: String, reasoning: String)? {
        guard case .assistantMessage(let message) = ChatEventDecoder.decode(record.event),
              message.stream != nil else { return nil }
        var text = ""
        var reasoning = ""
        for block in message.content {
            switch block {
            case .text(let value): text += value
            case .reasoning(let value): reasoning += value
            default: break
            }
        }
        return (text, reasoning)
    }

    // MARK: - 折叠与落地

    /// 重建：读 topExhausted → 折叠（离主线程）→ 代数校验 → 落回 model。
    /// 只有缺口变化时跳过整树折叠（spinner → 点击重试不碰数据行）。
    private func refold(messagesChanged: Bool, gapsChanged: Bool) {
        guard messagesChanged || gapsChanged else { return }
        foldGeneration += 1
        let generation = foldGeneration
        let snapshot = records.sorted { $0.key < $1.key }.map(\.value)
        let currentGaps = gaps
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            let exhausted = await self.session?.topExhausted ?? false
            let gapItems = self.gapItems(currentGaps, topExhausted: exhausted)
            guard messagesChanged else {
                model.applyPipelineGaps(gapItems)
                return
            }
            let folded = await Task.detached(priority: .userInitiated) {
                var timeline = ChatTimeline()
                _ = timeline.reset(with: snapshot)
                return timeline
            }.value
            guard generation == self.foldGeneration else { return }
            self.topExhausted = exhausted
            model.applyPipelineRebuild(
                folded, gaps: gapItems,
                topExhausted: exhausted, oldestSeq: self.records.keys.min())
        }
    }

    /// 缺口行集合：管道派生的中间缺口 + 顶部合成行（向上拉的 spinner 与中间
    /// 缺口是同一机制——前者是「窗口最顶端之上的缺口」，spec「缺口行的生命周期」）。
    /// 尾部追平（点胶囊/可见性兜底，T018/T019）期间再补一行合成**底部**缺口
    /// （spinner），区间集不表达"窗口之外的尾巴"，由这里显式占位。
    private func gapItems(
        _ pipelineGaps: [SessionPipeline.GapRow], topExhausted: Bool
    ) -> [TimelineItem] {
        var items = pipelineGaps.map { gap in
            ChatTimeline.gapItem(start: gap.start, end: gap.end, status: Self.map(gap.status))
        }
        if let top = topGapItem(topExhausted: topExhausted) {
            items.insert(top, at: 0)
        }
        if model?.isCatchingUpTail == true {
            // seq 取 Int.max-1：合成身份，排序恒在最后，不与任何真实缺口/数据行撞键。
            items.append(ChatTimeline.gapItem(start: .max - 1, end: .max - 1, status: .loading))
        }
        return items
    }

    /// 顶部合成行：已到最早（仅 topExhausted）> 失败可重试 > 加载中。
    /// start=0 是合成身份（`gap:0-0`），排序恒在最前，不与任何真实缺口撞键。
    private func topGapItem(topExhausted: Bool) -> TimelineItem? {
        if topExhausted {
            return ChatTimeline.gapItem(start: 0, end: 0, status: .exhausted)
        }
        if olderFailure != nil {
            return ChatTimeline.gapItem(start: 0, end: 0, status: .failed(retryable: true))
        }
        if isLoadingOlder {
            return ChatTimeline.gapItem(start: 0, end: 0, status: .loading)
        }
        return nil
    }

    private static func map(_ status: SessionPipeline.GapRow.Status) -> TimelineItem.GapStatus {
        switch status {
        case .loading: return .loading
        case .failed(let retryable): return .failed(retryable: retryable)
        case .exhausted: return .exhausted
        }
    }

    // MARK: - 用户动作（转发管道）

    /// 向上翻页（.userVisible）：向管道请求窗口之上的对齐范围。
    /// 命中区间零网络零 spinner；缺口由管道拉取并走 diff 回填。
    func loadOlder() async {
        guard let model, let session, !isLoadingOlder else { return }
        guard let oldest = records.keys.min(), oldest > 1 else { return }
        isLoadingOlder = true
        olderFailure = nil
        model.notePipelineLoadingOlder(true)
        model.notePipelineOlderFailure(nil)
        refold(messagesChanged: false, gapsChanged: true) // 顶部 spinner 立即出现
        defer {
            isLoadingOlder = false
            model.notePipelineLoadingOlder(false)
            refold(messagesChanged: false, gapsChanged: true)
        }
        let lower = max(1, oldest - Self.pageSize)
        do {
            _ = try await session.records(in: lower...(oldest - 1), priority: .userVisible)
            didAutoRetry = false
        } catch {
            // 失败绝不写成「没有更多」（T016）：顶部行转「点击重试」，并补试一次。
            olderFailure = String(localized: "读取更早的记录失败，点按重试")
            model.notePipelineOlderFailure(olderFailure)
            scheduleAutoRetry()
        }
    }

    /// 跳转（.jump）：抢占在途低优预取，只拉目标附近一段；返回命中行的 id。
    func rebase(around seq: Int, leading: Int, limit: Int) async -> String? {
        guard let model, let session else { return nil }
        let upper = seq + leading
        let lower = max(1, upper - limit + 1)
        _ = try? await session.records(in: lower...upper, priority: .jump)
        // diff → 折叠是异步的：命中行落地的判定交给短轮询（视图侧另有滚动梯子兜底）。
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return nil }
            if let row = TranscriptHitLocator.row(forSeq: seq, in: model.timeline.items) {
                return row.id
            }
        }
        return nil
    }

    /// 缺口行「点击重试」（T016）：清掉失败计数再拉；顶部行等价于重试向上翻页。
    func retryGap(start: Int, end: Int) async {
        guard let session else { return }
        if start == 0 {
            olderFailure = nil
            didAutoRetry = false
            await loadOlder()
            return
        }
        try? await session.retry(range: start...end)
    }

    /// 预算裁剪同步（008 FR-002）：模型丢到哪条，桥里的记录也丢到哪条，
    /// 否则下一次 diff 重建会把刚丢的行补回来。
    func dropRecords(below seq: Int) {
        records = records.filter { $0.key >= seq }
    }

    // MARK: - 尾部追平（T018 点胶囊 / T019 可见性兜底）

    /// 桥已收到的最大 seq（"本地对到哪儿了"的口径）。
    func localNewestSeq() -> Int { records.keys.max() ?? 0 }

    /// 尾部追平展示态变了（模型侧的 isCatchingUpTail）：底部合成缺口行生灭。
    func noteCatchUpPresentationChanged() {
        refold(messagesChanged: false, gapsChanged: true)
    }

    /// 把尾部对到 host 的 lastSeq（spec 009 场景 7 /「可见性兜底」）。
    ///
    /// - 差值 ≤ 5 页：`records(in:, .userVisible)` 逐段补齐，diff 正常回填，
    ///   底部 spinner 由 `isCatchingUpTail` 期间的合成缺口行表达；
    /// - 差值 > 5 页：降级为直接跳最新页（.jump），中间段丢弃——与跳转同语义，
    ///   留下的洞是普通的中间缺口行（点它可按既有重试路径补齐）。
    /// 幂等由管道的 in-flight 页表保证（同页合并）。
    func catchUp(toHost lastSeq: Int) async {
        guard let session, lastSeq > 0 else { return }
        let localNewest = records.keys.max() ?? 0
        let missing = lastSeq - localNewest
        guard missing > 0 else { return }
        if missing > Self.pageSize * Self.catchUpPageBudget {
            let lower = max(1, lastSeq - Self.pageSize + 1)
            _ = try? await session.records(in: lower...lastSeq, priority: .jump)
        } else {
            _ = try? await session.records(in: (localNewest + 1)...lastSeq, priority: .userVisible)
        }
    }

    /// 点胶囊直跳最新的降级阈值（页）：超过就丢中间段（spec 场景 7）。
    private static let catchUpPageBudget = 5

    /// 下行数据进管道（follow 快照 / WSS 事件）：合并进热窗口并经 diff 重建。
    func applyDownstream(records page: [SessionRecord]) {
        applyDownstream(events: page.map(\.event))
    }

    func applyDownstream(event: SessionEvent) {
        applyDownstream(events: [event])
    }

    /// 流式帧进管道（T020）：经 SessionPipeline 的 frameTick 合并成 diff，
    /// App 侧旧的 120ms 合流在管道模式下退役（非管道路径仍走 ChatModel 本地缓冲）。
    func applyDownstream(stream frame: AssistantStreamFrame) {
        Task { @MainActor [weak self] in
            await self?.session?.apply(stream: frame)
        }
    }

    private func applyDownstream(events: [SessionEvent]) {
        guard session != nil, !events.isEmpty else { return }
        // 批量入口：一份快照合并成一次 diff，避免按条数触发重建。
        Task { @MainActor [weak self] in
            await self?.session?.apply(events: events)
        }
    }

    /// 失败后的一次自动补试（读者停在顶部时没有任何几何变化可触发重试）。
    private func scheduleAutoRetry() {
        guard !didAutoRetry else { return }
        didAutoRetry = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(3000))
            guard !Task.isCancelled, let self, self.olderFailure != nil else { return }
            await self.loadOlder()
        }
    }
}
