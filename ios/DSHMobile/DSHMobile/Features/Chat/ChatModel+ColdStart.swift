import DSHKit
import Foundation

/// 进会话首帧的 009 磁盘层叠加（task T012，spec 009「冷启动流程」第 3 步）。
///
/// 与现有 `TranscriptStore` 尾部恢复**并存**：MessageStore 对该会话有数据
/// （持久化区间非空）时优先用它的最新页画首帧，读不出来或没数据时回退
/// 现有逻辑——老用户的 009 磁盘层是空的，行为与现状一致。这不是替换
/// TranscriptStore（那是 T027），只是让 009 落库的数据能被首帧用上。
extension ChatModel {

    /// 首帧数据源：MessageStore 优先，TranscriptStore 兜底。
    /// 返回形状与现有恢复路径一致，open() 的 syncPlan/贴底逻辑不变。
    func loadColdStartTail(scope: String, sessionId: String) async -> StoredTail? {
        if let tail = await loadMessageStoreTail(scope: scope, sessionId: sessionId) {
            return tail
        }
        return await loadStoredTail(scope: scope, sessionId: sessionId)
    }

    /// 009 磁盘层里的最新页。`ranges` 为空说明 009 从没水合过这个会话，
    /// 直接判没有（不去读盘碰运气）；区间声称覆盖但磁盘短收时同样回退。
    private func loadMessageStoreTail(scope: String, sessionId: String) async -> StoredTail? {
        guard let store = messageLayer?.store,
              let states = try? await store.sessionStates(scope: scope),
              let entry = states.first(where: { $0.sessionId == sessionId }),
              !entry.ranges.isEmpty, let newest = entry.newestSeq
        else { return nil }
        let lower = max(1, newest - Self.coldStartPageSize + 1)
        let records = (try? await store.records(scope: scope, sessionId: sessionId, in: lower...newest)) ?? []
        guard !records.isEmpty else { return nil }
        let oldest = records.first?.event.seq
        ViewportProbe.note("transcript.messageStore", [
            "session": sessionId,
            "records": String(records.count),
        ], force: true)
        return StoredTail(records: records, oldest: oldest, newest: newest,
                          hasOlder: (oldest ?? 1) > 1 || entry.hasMore)
    }

    /// 与 009 管道的页大小一致（一页 50 条）。
    private static let coldStartPageSize = 50

    /// 点开的会话以 .jump 插队水合最新页（T011：用户操作抢占在途低优预取）。
    /// 水合结果经 009 管道落库，下次冷启动首帧直接命中磁盘。失败静默：
    /// 会话内容照旧由 follow 快照提供，预取不许成为错误来源。
    func warmMessageLayer(for summary: SessionSummary) {
        guard let pipeline = messageLayer?.pipeline,
              let scope = sessionScope, summary.asOfSeq > 0
        else { return }
        messageLayer?.registerAddresses([summary])
        let target = MessagePipeline.PrefetchTarget(
            session: .init(scope: scope, sessionId: summary.sessionId),
            newestSeq: summary.asOfSeq)
        Task(priority: .utility) {
            await pipeline.prefetchLatestPages(
                [target], limit: 1, concurrency: 1, priority: .jump)
        }
    }
}
