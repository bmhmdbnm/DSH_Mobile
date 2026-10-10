import Foundation

/// 多会话内存层枢纽（spec 009 架构决定 §1/§2 / tasks T009 / contracts/memory-pipeline.md）。
///
/// 每会话懒建一个 `SessionPipeline`；对外只暴露契约面：
/// - `snapshots(for:)`：首次订阅立即吐出当前快照（`SnapshotDiff` 的 insert 全量），
///   之后只发增量 diff（insert/remove/update + gap 行生灭合并在同一次 diff）。
///   多订阅者各自一条独立 AsyncStream，互不影响。
/// - `send(text:)`：上行五拍——稳定 UUID clientId → 乐观插入（pending，身份即
///   clientId）→ 落库队列 → 网络（注入的 sender）→ 确认后 tempId→serverId
///   **原地替换**（UUID 身份不变，行高不变，spec 场景 11）。
///
/// 行身份纪律：数据行出现即排版完成（A 类由 SessionPipeline 水合时回填）；
/// 身份 = UUID，排序键 = seq；pending 用合成 seq（Int.max 起递减）排在末尾，
/// 确认后换正式 seq 不换身份。
public actor MessagePipeline {

    // MARK: - 契约类型（contracts/memory-pipeline.md）

    /// 订阅键：磁盘/网络两侧都靠 (scope, sessionId) 定位一个会话。
    public struct SessionRef: Hashable, Sendable {
        public let scope: String
        public let sessionId: String

        public init(scope: String, sessionId: String) {
            self.scope = scope
            self.sessionId = sessionId
        }
    }

    /// 数据行：排版已完成的不可变快照。`id` 是稳定 UUID，状态变化不改身份。
    public struct RenderedMessage: Identifiable, Sendable {
        public enum Status: String, Sendable, Equatable {
            case sent, pending, failed
        }

        public let id: UUID
        /// 排序键：正式消息是服务端 seq；pending 是合成键（见 SessionState）。
        public let seq: Int
        public let record: SessionRecord
        public let status: Status

        public init(id: UUID, seq: Int, record: SessionRecord, status: Status) {
            self.id = id
            self.seq = seq
            self.record = record
            self.status = status
        }
    }

    /// 行：数据行或缺口行（gap 身份 `gap:<start>-<end>` 由区间集派生）。
    public enum Row: Identifiable, Sendable {
        case message(RenderedMessage)
        case gap(GapRow)

        public var id: String {
            switch self {
            case .message(let message): return message.id.uuidString
            case .gap(let gap): return gap.id
            }
        }
    }

    public typealias GapRow = SessionPipeline.GapRow

    /// 一次原子提交（契约：changes 一次应用；anchor 由控件层按视口实况填）。
    public struct SnapshotDiff: Sendable {
        /// 视口顶部首个完整可见行 seq + 行内偏移（唯一位移锚，spec「唯一位移锚」）。
        /// 内存层不知道视口，由接收方在应用时填；内存层恒发 nil。
        public struct Anchor: Sendable, Equatable {
            public let seq: Int
            public let offset: Double

            public init(seq: Int, offset: Double) {
                self.seq = seq
                self.offset = offset
            }
        }

        public let anchor: Anchor?
        public let changes: [Change]

        public enum Change: Sendable {
            case insert([Row])
            case remove([String]) // RowID
            case update([Row])
        }

        public init(anchor: Anchor? = nil, changes: [Change]) {
            self.anchor = anchor
            self.changes = changes
        }
    }

    /// 上行发送的网络面（测试注入假回包）：返回服务端确认的正式记录。
    public typealias Sender = @Sendable (SessionRef, String, UUID) async throws -> SessionRecord
    /// 每会话的取页器工厂（产品适配 TranscriptPageFetcher，测试给假 fetcher）。
    public typealias PageFetchFactory = @Sendable (SessionRef) -> SessionPipeline.PageFetch

    // MARK: - 状态

    private let store: MessageStore?
    private let fetchFactory: PageFetchFactory
    private let sender: Sender
    private let frameTick: @Sendable () async -> Void
    private let now: @Sendable () -> TimeInterval
    private let pageSize: Int
    private let hotLimit: Int

    private var pipelines: [SessionRef: SessionPipeline] = [:]
    private var states: [SessionRef: SessionState] = [:]

    /// 每会话的聚合状态：行表 + 订阅者 + 泵任务。
    private struct SessionState {
        /// 行表：排序键 → 渲染消息（pending 用 Int.max 起递减的合成键）。
        var rows: [Int: RenderedMessage] = [:]
        /// 下行数据行的身份映射：seq → UUID（身份稳定，重复水合不换 id）。
        var identities: [Int: UUID] = [:]
        /// clientId → 合成 seq（确认时找到要原地替换的行）。
        var pendingSeqs: [UUID: Int] = [:]
        var nextSyntheticSeq = Int.max
        var gaps: [GapRow] = []
        var continuations: [UUID: AsyncStream<SnapshotDiff>.Continuation] = [:]
        var pump: Task<Void, Never>?
    }

    public init(
        store: MessageStore?,
        fetchFactory: @escaping PageFetchFactory,
        sender: @escaping Sender,
        frameTick: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        pageSize: Int = 50,
        hotLimit: Int = 500
    ) {
        self.store = store
        self.fetchFactory = fetchFactory
        self.sender = sender
        self.frameTick = frameTick
        self.now = now
        self.pageSize = pageSize
        self.hotLimit = hotLimit
    }

    // MARK: - 会话访问（产品/测试入口）

    /// 某会话的 SessionPipeline（懒建）。拉取/推送合并在这一层之下。
    public func pipeline(for session: SessionRef) -> SessionPipeline {
        if let pipeline = pipelines[session] { return pipeline }
        let store = self.store
        let pipeline = SessionPipeline(
            scope: session.scope, sessionId: session.sessionId,
            store: store, fetch: fetchFactory(session),
            frameTick: frameTick, now: now,
            pageSize: pageSize, hotLimit: hotLimit,
            flushWrites: { changes in
                // 落库低优先级批量写（spec §3：崩丢由「取用失败即拉取」兜底）。
                guard let store else { return }
                Task { try? await store.applyWrites(changes) }
            })
        pipelines[session] = pipeline
        return pipeline
    }

    // MARK: - 快照订阅（契约面）

    /// 订阅某会话的快照流。首帧是当前快照（可能只有 gap 行），之后是增量。
    public func snapshots(for session: SessionRef) async -> AsyncStream<SnapshotDiff> {
        let subscriptionID = UUID()
        let initial = await ensurePrimedState(for: session)
        return AsyncStream { continuation in
            states[session]?.continuations[subscriptionID] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscription(subscriptionID, for: session) }
            }
        }
    }

    private func removeSubscription(_ id: UUID, for session: SessionRef) {
        states[session]?.continuations.removeValue(forKey: id)
    }

    /// 懒建聚合状态：用 SessionPipeline 现有快照 prime（订阅前已水合的数据
    /// 不能丢），再启动泵（把 SessionPipeline 的 Diff 翻译成 SnapshotDiff 广播）。
    /// 返回该订阅的首帧（当前全量）。
    private func ensurePrimedState(for session: SessionRef) async -> SnapshotDiff {
        if let state = states[session] {
            return snapshotDiff(state)
        }
        let pipeline = pipeline(for: session)
        let (records, gaps) = await pipeline.snapshot()
        var state = SessionState()
        for record in records {
            let id = UUID()
            state.identities[record.event.seq] = id
            state.rows[record.event.seq] = RenderedMessage(
                id: id, seq: record.event.seq, record: record, status: .sent)
        }
        state.gaps = gaps
        states[session] = state
        let pump = Task { [weak self] in
            for await diff in await pipeline.diffs() {
                await self?.applyPipelineDiff(diff, for: session)
            }
        }
        states[session]?.pump = pump
        return snapshotDiff(state)
    }

    /// 当前全量行 → 首帧快照（insert 一次给出，升序）。
    private func snapshotDiff(_ state: SessionState) -> SnapshotDiff {
        let rows = currentRows(state)
        return SnapshotDiff(changes: rows.isEmpty ? [] : [.insert(rows)])
    }

    /// 全量有序行：数据行按 seq 升序，gap 行按区间位置插入。
    private func currentRows(_ state: SessionState) -> [Row] {
        let messages = state.rows.sorted { $0.key < $1.key }.map { Row.message($0.value) }
        var result = messages
        for gap in state.gaps.sorted(by: { $0.start < $1.start }) {
            let index = result.firstIndex { row in
                if case .message(let message) = row { return message.seq > gap.start }
                return false
            } ?? result.count
            result.insert(.gap(gap), at: index)
        }
        return result
    }

    // MARK: - 下行：SessionPipeline.Diff → SnapshotDiff 广播

    private func applyPipelineDiff(_ diff: SessionPipeline.Diff, for session: SessionRef) {
        guard var state = states[session] else { return }
        var changes: [SnapshotDiff.Change] = []

        let removed = diff.removed.compactMap { seq -> String? in
            guard let id = state.identities[seq] else { return nil }
            state.identities.removeValue(forKey: seq)
            state.rows.removeValue(forKey: seq)
            return id.uuidString
        }
        if !removed.isEmpty { changes.append(.remove(removed)) }

        // pending 确认后 WSS 回流同 seq：行已存在 → update，否则 insert（身份稳定）。
        var insertedRows: [Row] = []
        var reclassifiedUpdates: [Row] = []
        for record in diff.inserted {
            let id = state.identities[record.event.seq] ?? {
                let id = UUID()
                state.identities[record.event.seq] = id
                return id
            }()
            let message = RenderedMessage(id: id, seq: record.event.seq, record: record, status: .sent)
            let isNew = state.rows[record.event.seq] == nil
            state.rows[record.event.seq] = message
            if isNew { insertedRows.append(.message(message)) } else { reclassifiedUpdates.append(.message(message)) }
        }
        if !insertedRows.isEmpty { changes.append(.insert(insertedRows)) }

        var updatedRows: [Row] = reclassifiedUpdates
        updatedRows += diff.updated.compactMap { record in
            guard let id = state.identities[record.event.seq] else { return nil }
            let message = RenderedMessage(id: id, seq: record.event.seq, record: record, status: .sent)
            state.rows[record.event.seq] = message
            return .message(message)
        }
        if !updatedRows.isEmpty { changes.append(.update(updatedRows)) }

        // gap 行生灭与数据行变化合并在同一次 diff（契约规则 4）。
        changes.append(contentsOf: gapChanges(from: state.gaps, to: diff.gaps))
        state.gaps = diff.gaps

        states[session] = state
        guard !changes.isEmpty else { return }
        broadcast(SnapshotDiff(changes: changes), to: state.continuations)
    }

    /// 两组 gap（派生量）比对出生灭：消失的整体 remove，新生/状态变化 insert/update。
    private func gapChanges(from old: [GapRow], to new: [GapRow]) -> [SnapshotDiff.Change] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        let removedIDs = old.filter { newByID[$0.id] == nil }.map(\.id)
        var changes: [SnapshotDiff.Change] = []
        if !removedIDs.isEmpty { changes.append(.remove(removedIDs)) }
        let inserted = new.filter { oldByID[$0.id] == nil }.map(Row.gap)
        if !inserted.isEmpty { changes.append(.insert(inserted)) }
        let updated = new.filter { oldByID[$0.id] != nil && oldByID[$0.id] != $0 }.map(Row.gap)
        if !updated.isEmpty { changes.append(.update(updated)) }
        return changes
    }

    // MARK: - 上行：发送五拍（spec 场景 11 / 状态机 draft→pending→sent）

    /// 发送一条用户消息。乐观插入（pending，UUID 身份）→ 落库 → 网络 →
    /// 确认后原地替换（身份不变）。失败标 failed（可重发，不丢身份）。
    @discardableResult
    public func send(text: String, to session: SessionRef) async throws -> UUID {
        _ = await ensurePrimedState(for: session)
        let clientId = UUID()
        guard var state = states[session] else { return clientId }

        // ① 稳定 UUID + 合成 seq（排在当前尾部之后）。
        let syntheticSeq = state.nextSyntheticSeq
        state.nextSyntheticSeq -= 1
        let pending = SessionRecord(event: SessionEvent(
            type: "user/message", seq: syntheticSeq, time: now() * 1000,
            data: .object(["text": .string(text)]), surfaceOp: nil))
        let message = RenderedMessage(id: clientId, seq: syntheticSeq, record: pending, status: .pending)
        state.rows[syntheticSeq] = message
        state.pendingSeqs[clientId] = syntheticSeq
        states[session] = state
        broadcast(SnapshotDiff(changes: [.insert([.message(message)])]), to: state.continuations)

        // ② 落库队列（按消息去重，先落 pending 再发——重启可见未发出消息）。
        let pipeline = pipeline(for: session)
        await pipeline.enqueueWrite(.upsertPending(
            scope: session.scope, sessionId: session.sessionId,
            clientId: clientId.uuidString, record: pending), key: syntheticSeq)

        // ③ 网络 → ④ 确认原地替换 / 失败标 failed。
        do {
            let confirmed = try await sender(session, text, clientId)
            replacePending(clientId: clientId, with: confirmed, status: .sent, for: session)
            await pipeline.enqueueWrite(.confirmPending(
                scope: session.scope, sessionId: session.sessionId,
                clientId: clientId.uuidString, record: confirmed), key: confirmed.event.seq)
        } catch {
            replacePending(clientId: clientId, with: nil, status: .failed, for: session)
            throw error
        }
        return clientId
    }

    /// pending → sent/failed 原地替换：同一 UUID、同一行位置语义，只换内容与状态。
    private func replacePending(
        clientId: UUID, with confirmed: SessionRecord?,
        status: RenderedMessage.Status, for session: SessionRef
    ) {
        guard var state = states[session],
              let syntheticSeq = state.pendingSeqs[clientId],
              let old = state.rows[syntheticSeq]
        else { return }
        state.rows.removeValue(forKey: syntheticSeq)
        state.pendingSeqs.removeValue(forKey: clientId)
        let record = confirmed ?? old.record
        let seq = confirmed?.event.seq ?? syntheticSeq
        let message = RenderedMessage(id: clientId, seq: seq, record: record, status: status)
        state.rows[seq] = message
        if confirmed != nil { state.identities[seq] = clientId }
        states[session] = state
        broadcast(SnapshotDiff(changes: [.update([.message(message)])]), to: state.continuations)
    }

    private func broadcast(
        _ diff: SnapshotDiff,
        to continuations: [UUID: AsyncStream<SnapshotDiff>.Continuation]
    ) {
        for continuation in continuations.values {
            continuation.yield(diff)
        }
    }
}
