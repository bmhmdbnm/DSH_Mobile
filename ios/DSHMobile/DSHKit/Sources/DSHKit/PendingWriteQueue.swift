import Foundation

/// 批量落库队列（spec 009 架构决定 §3 / tasks T005）。
///
/// 两条纪律：
/// 1. **按消息去重**：同一 key 的多次入队只保留最新值——流式对同一行的反复更新
///    不产生写盘放大（spec「剩余卡顿源专项」之后补的规则）。
/// 2. **批量不紧急**：攒满 `maxBatch` 条或距上次落盘超过 `flushInterval` 才写；
///    崩丢由「取用失败即拉取」兜底，落库不追求实时（owner 已拍板）。
///
/// 纯值类型 + 注入时钟，快闸可测；并发安全由持有它的 actor 保证。
public struct PendingWriteQueue<Key: Hashable & Sendable, Value: Sendable>: Sendable {

    /// 入队上限/时间窗之一：条数阈值。
    public let maxBatch: Int
    /// 入队上限/时间窗之二：距上次落盘的最长间隔（秒）。
    public let flushInterval: TimeInterval

    /// 保持插入序：drain 时按序落盘，同一 key 只出现一次（最后一次的值）。
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    /// 本批第一个入队项的时刻：时间窗从这里起算（不是从上次落盘起算——
    /// 空队列的第一次入队不应触发立即落盘，冷启动批量灌库会被打散）。
    private var batchStartedAt: TimeInterval?

    public init(maxBatch: Int = 50, flushInterval: TimeInterval = 0.5) {
        self.maxBatch = maxBatch
        self.flushInterval = flushInterval
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// 入队一个变更。同 key 覆盖旧值并移到队尾（最新优先）。
    public mutating func enqueue(_ key: Key, _ value: Value, now: TimeInterval) {
        if values[key] == nil {
            order.append(key)
            if batchStartedAt == nil { batchStartedAt = now }
        } else if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        values[key] = value
    }

    /// 是否该落盘了：攒满，或距本批首次入队超时。
    public func shouldFlush(now: TimeInterval) -> Bool {
        guard !values.isEmpty else { return false }
        if values.count >= maxBatch { return true }
        guard let batchStartedAt else { return false }
        return now - batchStartedAt >= flushInterval
    }

    /// 取出全部待写项（按插入序），并重置时间窗。
    public mutating func drain(now: TimeInterval) -> [(key: Key, value: Value)] {
        let batch = order.compactMap { key -> (key: Key, value: Value)? in
            guard let value = values[key] else { return nil }
            return (key, value)
        }
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        batchStartedAt = nil
        return batch
    }
}
